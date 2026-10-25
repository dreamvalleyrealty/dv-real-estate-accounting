-- Require reconciled deposits and account for pending debits before posting trust payments/transfers.
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
  v_available numeric(14,2);
begin
  select * into v
  from public.dv_accounting_seller_settlements
  where id = p_settlement_id
  for update;

  if not found then
    raise exception 'Seller settlement was not found.';
  end if;

  if v.status not in ('SELLER_PROCEEDS_CALCULATED','SELLER_PAID') then
    raise exception 'Save and verify the seller settlement before transferring commissions.';
  end if;

  if coalesce(v.deposit_held_amount, 0) + 0.005 < coalesce(v.listing_commission_amount, 0) + coalesce(v.cooperating_commission_amount, 0) + coalesce(v.commission_hst_amount, 0) then
    raise exception 'The held trust deposit is insufficient to fund the full commission transfer.';
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

  if not exists (
    select 1 from public.dv_accounting_bank_accounts
    where id = v.real_estate_trust_account_id and company_id = v.company_id and account_type = 'REAL_ESTATE_TRUST'
  ) then
    raise exception 'The selected Real Estate Trust account does not belong to this company.';
  end if;
  if not exists (
    select 1 from public.dv_accounting_bank_accounts
    where id = v.commission_trust_account_id and company_id = v.company_id and account_type = 'COMMISSION_TRUST'
  ) then
    raise exception 'The selected Commission Trust account does not belong to this company.';
  end if;
  select coalesce(ba.opening_balance, 0) + coalesce(sum(case when bt.reconciled then bt.amount else least(bt.amount,0) end), 0) into v_available
  from public.dv_accounting_bank_accounts ba
  left join public.dv_accounting_bank_transactions bt on bt.bank_account_id = ba.id
  where ba.id = v.real_estate_trust_account_id and ba.company_id = v.company_id
  group by ba.id, ba.opening_balance;
  if not found or coalesce(v_available, 0) + 0.005 < v_total then
    raise exception 'Insufficient available Real Estate Trust bank balance for the commission transfer.';
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

  -- Listing-side commission revenue is recognized only when the funds are transferred
  -- from Real Estate Trust to Commission Trust. Debit the trust liability and credit
  -- commission revenue and HST payable; this journal is balanced and is atomic with both
  -- trust ledger movements below.
  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
  values (v.company_id,'4000','Commission Revenue','REVENUE'),
         (v.company_id,'2400','HST Payable','LIABILITY'),
         (v.company_id,'2300','Real Estate Trust Liabilities','LIABILITY'),
         (v.company_id,'1015','Real Estate Trust Bank','ASSET'),
         (v.company_id,'1020','Commission Trust Bank','ASSET')
  on conflict(company_id,code) do nothing;
  declare
    v_rev_gl uuid;
    v_hst_gl uuid;
    v_trust_liability_gl uuid;
    v_real_estate_bank_gl uuid;
    v_commission_bank_gl uuid;
    v_journal_id uuid;
    v_revenue_amount numeric(14,2);
  begin
    select id into v_rev_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='4000';
    select id into v_hst_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2400';
    select id into v_trust_liability_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2300';
    select id into v_real_estate_bank_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='1015';
    select id into v_commission_bank_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='1020';
    v_revenue_amount := round(coalesce(v.listing_commission_amount,0)+coalesce(v.cooperating_commission_amount,0),2);
    insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
    values(v.company_id,p_transfer_date,'SELLER_COMMISSION_TRANSFER',v.id,'Recognize listing-side commission on trust transfer')
    returning id into v_journal_id;
    insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    values
      (v_journal_id,v_commission_bank_gl,v_total,0),
      (v_journal_id,v_real_estate_bank_gl,0,v_total),
      (v_journal_id,v_trust_liability_gl,v_total,0);
    if v_revenue_amount > 0 then
      insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      values(v_journal_id,v_rev_gl,0,v_revenue_amount);
    end if;
    if coalesce(v.commission_hst_amount,0) > 0 then
      insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      values(v_journal_id,v_hst_gl,0,round(v.commission_hst_amount,2));
    end if;
  end;

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

create or replace function public.dv_accounting_post_listing_seller_payment(p_payment_id uuid)
returns public.dv_accounting_seller_settlement_payments
language plpgsql security definer set search_path=public as $$
declare
  p public.dv_accounting_seller_settlement_payments%rowtype;
  s public.dv_accounting_seller_settlements%rowtype;
  v_client text;
  v_posted_id uuid;
  v_je uuid;
  v_trust_liability_gl uuid;
  v_real_estate_bank_gl uuid;
  v_available numeric(14,2);
begin
  select * into p from public.dv_accounting_seller_settlement_payments where id=p_payment_id for update;
  if not found then raise exception 'Seller payment record was not found.'; end if;
  select * into s from public.dv_accounting_seller_settlements where id=p.settlement_id for update;
  if not found then raise exception 'Seller settlement was not found.'; end if;
  if p.status not in ('PROCESSED','COMPLETED') then raise exception 'Save the payment details and process the payment before posting the disbursement.'; end if;
  if p.direction_storage_path is not null and coalesce(trim(p.payee_name),'')='' then raise exception 'Authorized payee is required.'; end if;
  if p.payment_date is null or coalesce(trim(p.reference),'')='' or p.payment_method is null then raise exception 'Payment date, method and reference are required.'; end if;
  if p.trust_transaction_id is not null then return p; end if;
  if not exists(select 1 from public.dv_accounting_bank_accounts ba where ba.id=s.real_estate_trust_account_id and ba.company_id=s.company_id and ba.account_type='REAL_ESTATE_TRUST' and ba.active=true) then
    raise exception 'Select an active Real Estate Trust account for this settlement.';
  end if;
  select coalesce(ba.opening_balance,0)+coalesce(sum(case when bt.reconciled then bt.amount else least(bt.amount,0) end),0)
    into v_available
    from public.dv_accounting_bank_accounts ba
    left join public.dv_accounting_bank_transactions bt on bt.bank_account_id=ba.id
    where ba.id=s.real_estate_trust_account_id and ba.company_id=s.company_id
    group by ba.id,ba.opening_balance;
  if not found or coalesce(v_available,0)+0.005<p.amount then
    raise exception 'Insufficient reconciled Real Estate Trust funds for this seller/landlord payment.';
  end if;
  select l.client_name into v_client from public.dv_accounting_trust_liabilities l
    where l.company_id=s.company_id and l.trust_account_type='REAL_ESTATE_TRUST' and l.matter=s.matter and l.direction='RECEIVABLE' and l.amount>0 order by l.created_at limit 1;
  if coalesce(trim(v_client),'')='' then raise exception 'Cannot identify the original trust deposit client for this transaction.'; end if;
  perform public.dv_accounting_post_trust_transaction(
    s.company_id,s.real_estate_trust_account_id,s.transaction_id,p.payment_date,'REAL_ESTATE_TRUST','DISBURSEMENT',
    v_client,s.matter,'Seller/landlord payment to '||p.payee_name||' - '||s.matter,p.amount,p.reference
  );
  select id into v_posted_id from public.dv_accounting_trust_transactions
    where transaction_id=s.transaction_id and bank_account_id=s.real_estate_trust_account_id and trust_account_type='REAL_ESTATE_TRUST'
      and direction='DISBURSEMENT' and matter=s.matter and reference=p.reference and amount=p.amount and status='POSTED'
    order by created_at desc limit 1;
  if v_posted_id is null then raise exception 'Trust disbursement did not post.'; end if;
  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
    values(s.company_id,'2300','Real Estate Trust Liabilities','LIABILITY'),
          (s.company_id,'1015','Real Estate Trust Bank','ASSET')
    on conflict(company_id,code) do nothing;
  select id into v_trust_liability_gl from public.dv_accounting_gl_accounts where company_id=s.company_id and code='2300';
  select id into v_real_estate_bank_gl from public.dv_accounting_gl_accounts where company_id=s.company_id and code='1015';
  insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
    values(s.company_id,p.payment_date,'SELLER_TRUST_DISBURSEMENT',p.id,'Seller/landlord trust payment - '||p.payee_name)
    returning id into v_je;
  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    values(v_je,v_trust_liability_gl,p.amount,0),(v_je,v_real_estate_bank_gl,0,p.amount);
  update public.dv_accounting_seller_settlement_payments set trust_transaction_id=v_posted_id,status='COMPLETED',completed_at=now(),updated_at=now(),updated_by=auth.uid()
    where id=p.id returning * into p;
  update public.dv_accounting_seller_settlements set seller_paid_amount=coalesce(seller_paid_amount,0)+p.amount,
    seller_payment_status='COMPLETED',seller_payment_reference=p.reference,seller_payment_date=p.payment_date,seller_payment_method=p.payment_method,
    seller_payment_audit=coalesce(seller_payment_audit,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('event','PAYMENT_COMPLETED','payment_id',p.id,'amount',p.amount,'payee',p.payee_name,'reference',p.reference,'at',now(),'by',auth.uid())),
    updated_at=now(),updated_by=auth.uid() where id=s.id;
  return p;
end $$;

grant execute on function public.dv_accounting_post_listing_seller_payment(uuid) to authenticated;
