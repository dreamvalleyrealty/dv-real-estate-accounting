-- Atomic posting for seller-side commission transfers.
-- The seller's payment is recorded as a lawyer-paid checkpoint; the brokerage's
-- trust ledger records only the inter-account commission transfer here.
alter table public.dv_accounting_seller_settlements
  add column if not exists seller_client_name text,
  add column if not exists matter text;

create or replace function public.dv_accounting_process_seller_commission_transfer(
  p_settlement_id uuid,
  p_transfer_reference text,
  p_transfer_date date
)
returns public.dv_accounting_seller_settlements
language plpgsql
set search_path = public
as $$
declare
  v public.dv_accounting_seller_settlements%rowtype;
  v_total numeric(14,2);
begin
  select * into v
  from public.dv_accounting_seller_settlements
  where id = p_settlement_id
  for update;

  if not found then
    raise exception 'Seller settlement was not found.';
  end if;

  if v.status <> 'SELLER_PAID' then
    raise exception 'Record and save full seller payment before transferring commission.';
  end if;

  if coalesce(v.seller_paid_amount, 0) < coalesce(v.seller_proceeds_amount, 0)
     or coalesce(nullif(trim(v.seller_payment_reference), ''), '') = ''
     or v.seller_payment_date is null then
    raise exception 'Seller payment must be fully recorded with reference and date.';
  end if;

  if v.real_estate_trust_account_id is null
     or v.commission_trust_account_id is null
     or v.real_estate_trust_account_id = v.commission_trust_account_id then
    raise exception 'Select two different trust accounts.';
  end if;

  if coalesce(nullif(trim(v.seller_client_name), ''), '') = ''
     or coalesce(nullif(trim(v.matter), ''), '') = '' then
    raise exception 'Seller/client name and trade number are required for the trust ledger.';
  end if;

  v_total := round(
    coalesce(v.listing_commission_amount, 0)
    + coalesce(v.cooperating_commission_amount, 0)
    + coalesce(v.commission_hst_amount, 0), 2
  );

  if v_total <= 0 then
    raise exception 'Commission transfer must be greater than zero.';
  end if;

  if coalesce(nullif(trim(p_transfer_reference), ''), '') = '' or p_transfer_date is null then
    raise exception 'Transfer reference and date are required.';
  end if;

  -- Both ledger posts occur in this database transaction. If either post fails,
  -- PostgreSQL rolls back both, preventing one-sided trust transfers.
  perform public.dv_accounting_post_trust_transaction(
    p_company_id => v.company_id,
    p_bank_account_id => v.real_estate_trust_account_id,
    p_transaction_id => v.transaction_id,
    p_ledger_date => p_transfer_date,
    p_trust_account_type => 'REAL_ESTATE_TRUST',
    p_direction => 'DISBURSEMENT',
    p_client_name => v.seller_client_name,
    p_matter => v.matter,
    p_description => 'Commission transfer to Commission Trust - ' || v.matter,
    p_amount => v_total,
    p_reference => trim(p_transfer_reference) || '-OUT'
  );

  perform public.dv_accounting_post_trust_transaction(
    p_company_id => v.company_id,
    p_bank_account_id => v.commission_trust_account_id,
    p_transaction_id => v.transaction_id,
    p_ledger_date => p_transfer_date,
    p_trust_account_type => 'COMMISSION_TRUST',
    p_direction => 'DEPOSIT',
    p_client_name => v.seller_client_name,
    p_matter => v.matter,
    p_description => 'Commission transfer received from Real Estate Trust - ' || v.matter,
    p_amount => v_total,
    p_reference => trim(p_transfer_reference) || '-IN'
  );

  update public.dv_accounting_seller_settlements
  set status = 'READY_FOR_COMMISSION_PAYROLL',
      commission_transfer_amount = v_total,
      commission_transfer_reference = trim(p_transfer_reference),
      commission_transfer_date = p_transfer_date,
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_settlement_id
  returning * into v;

  return v;
end;
$$;

comment on function public.dv_accounting_process_seller_commission_transfer(uuid,text,date)
is 'Posts the debit and credit for a seller-side commission transfer atomically and releases the settlement to Commission Payroll.';


create or replace function public.dv_accounting_prevent_seller_settlement_reversal()
returns trigger language plpgsql as $$
begin
  if old.status in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    if new.status not in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
      raise exception 'A posted seller commission transfer cannot be reverted to an earlier settlement stage.';
    end if;
    if new.company_id is distinct from old.company_id or new.transaction_id is distinct from old.transaction_id
       or new.seller_client_name is distinct from old.seller_client_name or new.matter is distinct from old.matter
       or new.listing_commission_amount is distinct from old.listing_commission_amount
       or new.cooperating_commission_amount is distinct from old.cooperating_commission_amount
       or new.commission_hst_amount is distinct from old.commission_hst_amount
       or new.real_estate_trust_account_id is distinct from old.real_estate_trust_account_id
       or new.commission_trust_account_id is distinct from old.commission_trust_account_id
       or new.commission_transfer_amount is distinct from old.commission_transfer_amount
       or new.commission_transfer_reference is distinct from old.commission_transfer_reference
       or new.commission_transfer_date is distinct from old.commission_transfer_date then
      raise exception 'Financial fields are locked after the commission trust transfer is posted.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists dv_accounting_seller_settlement_no_reversal on public.dv_accounting_seller_settlements;
create trigger dv_accounting_seller_settlement_no_reversal before update on public.dv_accounting_seller_settlements
for each row execute function public.dv_accounting_prevent_seller_settlement_reversal();
