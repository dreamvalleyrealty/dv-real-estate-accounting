create table if not exists public.dv_accounting_buyer_rebates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id),
  transaction_id uuid not null references public.dv_accounting_transactions(id),
  buyer_name text not null,
  amount numeric(14,2) not null check (amount > 0),
  reason text,
  agreement_reference text,
  status text not null default 'PENDING'
    check (status in ('PENDING','APPROVED','REJECTED','COMPLETED')),
  created_by uuid,
  created_at timestamptz not null default now(),
  approval_notes text,
  approved_by uuid,
  approved_at timestamptz,
  payment_date date,
  payment_method text,
  payment_reference text,
  commission_trust_account_id uuid references public.dv_accounting_bank_accounts(id),
  trust_transaction_id uuid references public.dv_accounting_trust_transactions(id),
  updated_at timestamptz not null default now()
);

create index if not exists dv_accounting_buyer_rebates_company_created_idx
  on public.dv_accounting_buyer_rebates(company_id, created_at desc);
create index if not exists dv_accounting_buyer_rebates_transaction_idx
  on public.dv_accounting_buyer_rebates(transaction_id);

alter table public.dv_accounting_buyer_rebates enable row level security;
grant select, insert on public.dv_accounting_buyer_rebates to authenticated;

drop policy if exists dv_buyer_rebates_select on public.dv_accounting_buyer_rebates;
create policy dv_buyer_rebates_select on public.dv_accounting_buyer_rebates
for select to authenticated
using (public.dv_accounting_has_any_permission_all_scope(array['transactions.view','reports.view','banking.view']));

drop policy if exists dv_buyer_rebates_insert on public.dv_accounting_buyer_rebates;
create policy dv_buyer_rebates_insert on public.dv_accounting_buyer_rebates
for insert to authenticated
with check (
  public.dv_accounting_has_permission_all_scope('transactions.create')
  and created_by = auth.uid()
);

create or replace function public.dv_accounting_validate_buyer_rebate_trade()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_side text; v_status text;
begin
  select upper(coalesce(t.side,'')), upper(coalesce(t.status,''))
    into v_side, v_status
  from public.dv_accounting_transactions t
  where t.id = new.transaction_id and t.company_id = new.company_id;
  if not found then raise exception 'Buyer rebate must be linked to a transaction in the same company.'; end if;
  if v_side <> 'BUYER' then raise exception 'Buyer rebates are only permitted when the brokerage represents the buyer.'; end if;
  if v_status <> 'CLOSED' then raise exception 'Buyer rebates can only be recorded for closed buyer-side trades.'; end if;
  if btrim(coalesce(new.buyer_name,'')) = '' then raise exception 'Buyer name is required.'; end if;
  return new;
end;
$$;

drop trigger if exists dv_accounting_buyer_rebate_trade_check on public.dv_accounting_buyer_rebates;
create trigger dv_accounting_buyer_rebate_trade_check
before insert or update of company_id, transaction_id, buyer_name
on public.dv_accounting_buyer_rebates
for each row execute function public.dv_accounting_validate_buyer_rebate_trade();

create or replace function public.dv_accounting_approve_buyer_rebate(
  p_rebate_id uuid, p_approved boolean, p_notes text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v public.dv_accounting_buyer_rebates%rowtype;
begin
  if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN','MANAGER') then
    raise exception 'Only management can approve or reject buyer rebates.';
  end if;
  select * into v from public.dv_accounting_buyer_rebates where id=p_rebate_id for update;
  if not found then raise exception 'Buyer rebate not found.'; end if;
  if v.status <> 'PENDING' then raise exception 'Only pending buyer rebates can be reviewed.'; end if;
  update public.dv_accounting_buyer_rebates
  set status=case when p_approved then 'APPROVED' else 'REJECTED' end,
      approval_notes=nullif(btrim(coalesce(p_notes,'')),''),
      approved_by=auth.uid(), approved_at=now(), updated_at=now()
  where id=p_rebate_id returning * into v;
  return jsonb_build_object('ok',true,'id',v.id,'status',v.status);
end;
$$;
revoke all on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) from public;
grant execute on function public.dv_accounting_approve_buyer_rebate(uuid,boolean,text) to authenticated;

create or replace function public.dv_accounting_post_buyer_rebate(
  p_rebate_id uuid, p_payment_date date, p_payment_method text,
  p_payment_reference text, p_commission_trust_account_id uuid
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v public.dv_accounting_buyer_rebates%rowtype;
  t public.dv_accounting_transactions%rowtype;
  ba public.dv_accounting_bank_accounts%rowtype;
  v_client text;
  v_matter text;
  v_result jsonb;
  v_trust_id uuid;
begin
  if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT') then
    raise exception 'You do not have permission to post buyer rebate payments.';
  end if;
  select * into v from public.dv_accounting_buyer_rebates where id=p_rebate_id for update;
  if not found then raise exception 'Buyer rebate not found.'; end if;
  if v.status <> 'APPROVED' then raise exception 'Only approved buyer rebates can be paid.'; end if;
  if p_payment_date is null or nullif(btrim(coalesce(p_payment_reference,'')),'') is null then
    raise exception 'Payment date and cheque/EFT reference are required.';
  end if;
  if upper(coalesce(p_payment_method,'')) not in ('CHEQUE','EFT') then
    raise exception 'Payment method must be CHEQUE or EFT.';
  end if;
  select * into t from public.dv_accounting_transactions
  where id=v.transaction_id and company_id=v.company_id for share;
  if not found or upper(coalesce(t.side,'')) <> 'BUYER' or upper(coalesce(t.status,'')) <> 'CLOSED' then
    raise exception 'Buyer rebate requires a closed buyer-side trade.';
  end if;
  select * into ba from public.dv_accounting_bank_accounts
  where id=p_commission_trust_account_id and company_id=v.company_id
    and upper(account_type)='COMMISSION_TRUST' and active=true;
  if not found then raise exception 'Select an active Commission Trust account belonging to this company.'; end if;

  select client_name, matter into v_client, v_matter
  from public.dv_accounting_trust_liabilities
  where company_id=v.company_id and transaction_id=v.transaction_id
    and trust_account_type='COMMISSION_TRUST'
  order by created_at desc limit 1;
  if v_matter is null then
    v_matter := coalesce(nullif(t.trade_number,''),nullif(t.transaction_number,''),t.id::text);
  end if;
  if v_client is null then v_client := v.buyer_name; end if;

  v_result := public.dv_accounting_post_trust_transaction(
    p_company_id=>v.company_id,
    p_bank_account_id=>ba.id,
    p_transaction_id=>v.transaction_id,
    p_ledger_date=>p_payment_date,
    p_trust_account_type=>'COMMISSION_TRUST',
    p_direction=>'DISBURSEMENT',
    p_client_name=>v_client,
    p_matter=>v_matter,
    p_description=>'Buyer rebate payment - '||v.buyer_name||' - '||v_matter,
    p_amount=>v.amount,
    p_reference=>btrim(p_payment_reference)
  );
  v_trust_id := (v_result->>'trust_transaction_id')::uuid;
  update public.dv_accounting_buyer_rebates
  set status='COMPLETED', payment_date=p_payment_date,
      payment_method=upper(p_payment_method), payment_reference=btrim(p_payment_reference),
      commission_trust_account_id=ba.id, trust_transaction_id=v_trust_id, updated_at=now()
  where id=v.id;
  return jsonb_build_object('ok',true,'status','COMPLETED','trust_transaction_id',v_trust_id,'trust_posting',v_result);
end;
$$;
revoke all on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) from public;
grant execute on function public.dv_accounting_post_buyer_rebate(uuid,date,text,text,uuid) to authenticated;
