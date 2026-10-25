-- Correctly advance settlement only after the aggregate seller balance is actually paid.
create or replace function public.dv_accounting_post_listing_seller_payment(p_payment_id uuid)
returns public.dv_accounting_seller_settlement_payments
language plpgsql security definer set search_path=public as $$
declare
  p public.dv_accounting_seller_settlement_payments%rowtype;
  s public.dv_accounting_seller_settlements%rowtype;
  v_client text;
  v_posted_id uuid;
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
  update public.dv_accounting_seller_settlement_payments set trust_transaction_id=v_posted_id,status='COMPLETED',completed_at=now(),updated_at=now(),updated_by=auth.uid()
    where id=p.id returning * into p;
  update public.dv_accounting_seller_settlements set
    seller_paid_amount=coalesce(seller_paid_amount,0)+p.amount,
    status=case when coalesce(seller_paid_amount,0)+p.amount+0.005 >= coalesce(seller_proceeds_amount,0) then 'SELLER_PAID' else status end,
    seller_payment_status=case when coalesce(seller_paid_amount,0)+p.amount+0.005 >= coalesce(seller_proceeds_amount,0) then 'COMPLETED' else 'PROCESSED' end,
    seller_payment_reference=p.reference,seller_payment_date=p.payment_date,seller_payment_method=p.payment_method,
    seller_payment_audit=coalesce(seller_payment_audit,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('event','PAYMENT_COMPLETED','payment_id',p.id,'amount',p.amount,'payee',p.payee_name,'reference',p.reference,'at',now(),'by',auth.uid())),
    updated_at=now(),updated_by=auth.uid() where id=s.id;
  return p;
end $$;

grant execute on function public.dv_accounting_post_listing_seller_payment(uuid) to authenticated;
