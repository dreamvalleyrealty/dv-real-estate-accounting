-- Step 1: seller/landlord proceeds completion and audited Superadmin reopening.
-- Posted trust ledger transactions are never deleted or reversed by reopening.

create or replace function public.dv_accounting_seller_proceeds_satisfied(p_settlement_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select coalesce(s.seller_proceeds_amount,0) <=
    coalesce((
      select sum(p.amount)
      from public.dv_accounting_seller_settlement_payments p
      join public.dv_accounting_trust_transactions tt
        on tt.id = p.trust_transaction_id
       and tt.transaction_id = p.transaction_id
       and tt.company_id = p.company_id
       and tt.direction = 'DISBURSEMENT'
       and tt.trust_account_type = 'REAL_ESTATE_TRUST'
       and upper(coalesce(tt.status,'')) = 'POSTED'
       and tt.amount = p.amount
       and tt.reference = p.reference
      where p.settlement_id = s.id
        and p.transaction_id = s.transaction_id
        and p.company_id = s.company_id
        and upper(coalesce(p.status,'')) = 'COMPLETED'
        and p.trust_transaction_id is not null
        and (
          upper(coalesce(p.payee_type,'')) in ('SELLER','LANDLORD')
          or (
            upper(coalesce(p.payee_type,'')) in ('LAWYER','THIRD_PARTY')
            and coalesce(nullif(trim(p.direction_storage_path),''),'') <> ''
          )
        )
    ),0) + 0.005
  from public.dv_accounting_seller_settlements s
  where s.id = p_settlement_id;
$function$;

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
  update public.dv_accounting_seller_settlements
  set seller_paid_amount=coalesce(seller_paid_amount,0)+case when upper(coalesce(p.payee_type,'')) in ('SELLER','LANDLORD') then p.amount else 0 end,
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
end $function$


CREATE OR REPLACE FUNCTION public.dv_accounting_validate_seller_settlement()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_commission_total numeric(14,2);
begin
  new.updated_at := now();
  v_commission_total := round(
    coalesce(new.listing_commission_amount, 0)
    + coalesce(new.cooperating_commission_amount, 0)
    + coalesce(new.commission_hst_amount, 0), 2
  );

  if new.status in ('SELLER_PAID','COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL',
                    'COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    if not public.dv_accounting_seller_proceeds_satisfied(new.id) then
      raise exception 'Seller must be paid in full before this settlement can advance.';
    end if;
    if coalesce(nullif(trim(new.seller_payment_reference), ''), '') = ''
       or new.seller_payment_date is null then
      raise exception 'Record the seller payment reference and date before advancing.';
    end if;
  end if;

  if new.status in ('COMMISSION_TRANSFERRED','READY_FOR_COMMISSION_PAYROLL',
                    'COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    if new.commission_transfer_amount <> v_commission_total then
      raise exception 'Commission trust transfer must equal listing commission plus cooperating commission plus HST.';
    end if;
    if coalesce(nullif(trim(new.commission_transfer_reference), ''), '') = ''
       or new.commission_transfer_date is null then
      raise exception 'Record the commission trust transfer reference and date before advancing.';
    end if;
    if new.real_estate_trust_account_id is null
       or new.commission_trust_account_id is null
       or new.real_estate_trust_account_id = new.commission_trust_account_id then
      raise exception 'Select two different trust accounts for the commission transfer.';
    end if;
  end if;

  if new.status in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED')
     and not public.dv_accounting_seller_proceeds_satisfied(new.id) then
    raise exception 'Commission Payroll is blocked until the seller is fully paid.';
  end if;

  if new.status = 'PAYMENTS_COMPLETED' then
    if new.listing_agent_paid_amount + new.cooperating_brokerage_paid_amount > new.commission_transfer_amount then
      raise exception 'Recorded commission payments cannot exceed the transferred commission funds.';
    end if;
    new.payments_completed_at := coalesce(new.payments_completed_at, now());
  end if;

  return new;
end;
$function$


create or replace function public.dv_accounting_reopen_seller_settlement(
  p_settlement_id uuid,
  p_reason text
)
returns public.dv_accounting_seller_settlements
language plpgsql
security definer
set search_path = public
as $function$
declare
  v public.dv_accounting_seller_settlements%rowtype;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to reopen a seller/landlord settlement.';
  end if;
  select upper(regexp_replace(coalesce(role,''),'[^A-Z]','','g'))
    into v_role
  from public.dv_accounting_user_profiles
  where user_id = auth.uid() and active = true
  limit 1;
  if v_role not in ('SUPERADMIN','SUPERADMINISTRATOR') then
    raise exception 'Only active Superadmins can reopen completed Seller/Landlord Settlements.';
  end if;
  if coalesce(trim(p_reason),'') = '' then
    raise exception 'A reason is required to reopen a settlement.';
  end if;
  select * into v
  from public.dv_accounting_seller_settlements
  where id = p_settlement_id
  for update;
  if not found then
    raise exception 'Seller/landlord settlement was not found.';
  end if;
  if v.status not in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
    raise exception 'Only completed or commission-payroll-stage settlements can be reopened.';
  end if;
  update public.dv_accounting_seller_settlements
  set status = 'REOPENED',
      seller_payment_audit = coalesce(seller_payment_audit,'[]'::jsonb) ||
        jsonb_build_array(jsonb_build_object(
          'event','SETTLEMENT_REOPENED',
          'previous_status',v.status,
          'reason',trim(p_reason),
          'at',now(),
          'by',auth.uid()
        )),
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_settlement_id
  returning * into v;
  return v;
end;
$function$;

revoke all on function public.dv_accounting_reopen_seller_settlement(uuid,text) from public;
grant execute on function public.dv_accounting_reopen_seller_settlement(uuid,text) to authenticated;
revoke all on function public.dv_accounting_seller_proceeds_satisfied(uuid) from public;
grant execute on function public.dv_accounting_seller_proceeds_satisfied(uuid) to authenticated;
