-- Seller/landlord disbursements use posted client trust-ledger funds, not bank reconciliation status.
-- Fail closed when the posted deposit's trade/client association does not match the settlement.

CREATE OR REPLACE FUNCTION public.dv_accounting_post_listing_seller_payment(p_payment_id uuid)
 RETURNS dv_accounting_seller_settlement_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p public.dv_accounting_seller_settlement_payments%rowtype;
  s public.dv_accounting_seller_settlements%rowtype;
  v_client text;
  v_deposit_matter text;
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
  -- Identify the original posted deposit for this transaction and account.
  -- A bank reconciliation flag is not a trust-ledger posting requirement.
  select tt.client_name, tt.matter
    into v_client, v_deposit_matter
    from public.dv_accounting_trust_transactions tt
    where tt.company_id=s.company_id
      and tt.transaction_id=s.transaction_id
      and tt.bank_account_id=s.real_estate_trust_account_id
      and tt.trust_account_type='REAL_ESTATE_TRUST'
      and tt.direction='DEPOSIT'
      and upper(coalesce(tt.status,''))='POSTED'
      and tt.amount > 0
    order by tt.created_at
    limit 1;
  if coalesce(trim(v_client),'')='' then
    raise exception 'Cannot identify a posted Real Estate Trust deposit for this transaction.';
  end if;
  if coalesce(trim(v_deposit_matter),'') <> coalesce(trim(s.matter),'') then
    raise exception 'The posted trust deposit trade reference (%) does not match this settlement (%). Correct the deposit-to-trade association before disbursing.', v_deposit_matter, s.matter;
  end if;
  if coalesce(trim(v_client),'') <> coalesce(trim(s.seller_client_name),'') then
    raise exception 'The posted trust deposit client (%) does not match the settlement client (%). Correct the client association before disbursing.', v_client, s.seller_client_name;
  end if;

  -- Available funds are the posted trust-ledger balance for this exact client,
  -- matter, transaction, and trust account, independent of bank reconciliation.
  select coalesce(sum(case when tt.direction='DEPOSIT' then tt.amount
                           when tt.direction='DISBURSEMENT' then -tt.amount
                           else 0 end),0)
    into v_available
    from public.dv_accounting_trust_transactions tt
    where tt.company_id=s.company_id
      and tt.transaction_id=s.transaction_id
      and tt.bank_account_id=s.real_estate_trust_account_id
      and tt.trust_account_type='REAL_ESTATE_TRUST'
      and tt.client_name=v_client
      and tt.matter=s.matter
      and upper(coalesce(tt.status,''))='POSTED'
      and tt.direction in ('DEPOSIT','DISBURSEMENT');
  if coalesce(v_available,0)+0.005<p.amount then
    raise exception 'Insufficient posted trust-ledger funds for this client and trade. Available: %, payment: %.', coalesce(v_available,0), p.amount;
  end if;
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
  update public.dv_accounting_seller_settlements
  set seller_paid_amount=coalesce((
      select sum(dp.amount)
      from public.dv_accounting_seller_settlement_payments dp
      where dp.settlement_id=s.id
        and dp.transaction_id=s.transaction_id
        and dp.company_id=s.company_id
        and upper(coalesce(dp.status,''))='COMPLETED'
        and dp.trust_transaction_id is not null
        and upper(coalesce(dp.payee_type,'')) in ('SELLER','LANDLORD')
    ),0),
    seller_payment_status='COMPLETED',
    seller_payment_reference=p.reference,
    seller_payment_date=p.payment_date,
    seller_payment_method=p.payment_method,
    status=case
      when status in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then status
      when public.dv_accounting_seller_proceeds_satisfied(s.id) then 'SELLER_PAID'
      else 'SELLER_PROCEEDS_CALCULATED'
    end,
    seller_payment_audit=coalesce(seller_payment_audit,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('event','PAYMENT_COMPLETED','payment_id',p.id,'amount',p.amount,'payee',p.payee_name,'payee_type',p.payee_type,'reference',p.reference,'at',now(),'by',auth.uid())),
    updated_at=now(),updated_by=auth.uid()
  where id=s.id;
  return p;
end $function$;
