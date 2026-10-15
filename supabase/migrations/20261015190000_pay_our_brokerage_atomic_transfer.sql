-- Atomically transfer the brokerage's percentage share from Commission Trust to General Operating.
create or replace function public.dv_accounting_pay_our_brokerage(p_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_company_id uuid;
  v_transaction_number text;
  v_gross numeric(14,2);
  v_agent_split numeric(7,4);
  v_hst_rate numeric(7,4);
  v_admin_fee numeric(14,2);
  v_cheque_fees numeric(14,2);
  v_amount numeric(14,2);
  v_cheque_date date;
  v_cheque_reference text;
  v_cheque_id uuid;
  v_source_account_id uuid;
  v_source_client text;
  v_source_matter text;
  v_destination_account_id uuid;
  v_reference text;
  v_existing_id uuid;
  v_role text;
begin
  select upper(coalesce(role,'')) into v_role from public.dv_accounting_user_profiles where user_id=auth.uid();
  if v_role not in ('SUPERADMIN','SUPERADMINISTRATOR') then raise exception 'Only a SuperAdmin may post the brokerage share transfer.'; end if;
  if p_transaction_id is null then raise exception 'Transaction is required.'; end if;
  select t.company_id,t.transaction_number,
         round(coalesce(nullif(t.commission_approved_amount,0),nullif(t.gross_commission,0),0)::numeric,2)
    into v_company_id,v_transaction_number,v_gross
  from public.dv_accounting_transactions t
  where t.id=p_transaction_id and upper(coalesce(t.status,''))='CLOSED'
  for update;
  if not found or v_company_id is null then raise exception 'Closed transaction was not found.'; end if;

  select q.id,coalesce(q.cheque_date,current_date),coalesce(nullif(trim(q.payment_reference),''),nullif(trim(q.cheque_number),'')),coalesce(q.total_fees,0)
    into v_cheque_id,v_cheque_date,v_cheque_reference,v_cheque_fees
  from public.dv_accounting_commission_cheques q
  join public.dv_accounting_commissions c on c.id=q.commission_id
  where c.transaction_id=p_transaction_id and upper(coalesce(q.status,''))='ISSUED'
  order by q.created_at desc limit 1;
  if v_cheque_id is null or coalesce(v_cheque_reference,'')='' then
    raise exception 'Record and issue the agent commission payment with a cheque/EFT reference first.';
  end if;

  select i.split_percent into v_agent_split
  from public.dv_accounting_transaction_agent_info i
  where i.transaction_id=p_transaction_id
  order by i.created_at desc limit 1;
  if v_agent_split is null or v_agent_split < 0 or v_agent_split > 100 then
    raise exception 'A valid agent split percentage is required to calculate the brokerage share.';
  end if;
  select coalesce(max(tc.hst_rate),13) into v_hst_rate
  from public.dv_accounting_transaction_commissions tc where tc.transaction_id=p_transaction_id;
  select coalesce(max(i.admin_fee),0) into v_admin_fee
  from public.dv_accounting_transaction_agent_info i where i.transaction_id=p_transaction_id;
  -- Brokerage share + HST on that share + HST on admin fee + all fees deducted from the issued agent cheque.
  v_amount := round(
    (v_gross * (100-v_agent_split) / 100)
    + ((v_gross * (100-v_agent_split) / 100) * v_hst_rate / 100)
    + (v_admin_fee * v_hst_rate / 100)
    + coalesce(v_cheque_fees,0), 2
  );
  if v_gross<=0 or v_amount<=0 then raise exception 'Calculated brokerage share must be greater than zero.'; end if;

  v_reference := 'OUR-BROKERAGE:'||p_transaction_id::text;
  select id into v_existing_id from public.dv_accounting_trust_transactions
  where reference=v_reference and trust_account_type='COMMISSION_TRUST' limit 1;
  if v_existing_id is not null then
    return jsonb_build_object('already_posted',true,'amount',v_amount,'reference',v_reference);
  end if;

  select id into v_source_account_id from public.dv_accounting_bank_accounts
  where company_id=v_company_id and account_type='COMMISSION_TRUST' and active is true
  order by created_at limit 1;
  if v_source_account_id is null then raise exception 'No active Commission Trust account was found.'; end if;

  select d.client_name,d.matter into v_source_client,v_source_matter
  from public.dv_accounting_trust_transactions d
  where d.transaction_id=p_transaction_id and d.company_id=v_company_id
    and d.trust_account_type='COMMISSION_TRUST' and d.direction='DEPOSIT' and d.status='POSTED'
  order by d.created_at desc limit 1;
  if coalesce(trim(v_source_client),'')='' then raise exception 'A posted Commission Trust deposit/client liability is required for this trade.'; end if;

  select id into v_destination_account_id from public.dv_accounting_bank_accounts
  where company_id=v_company_id and account_type='OPERATING' and active is true
  order by created_at limit 1;
  if v_destination_account_id is null then raise exception 'No active General Operating bank account was found.'; end if;

  perform public.dv_accounting_post_trust_transaction(
    v_company_id,v_source_account_id,p_transaction_id,v_cheque_date,
    'COMMISSION_TRUST','DISBURSEMENT',v_source_client,
    coalesce(nullif(v_source_matter,''),v_transaction_number),
    'Brokerage share transfer to General Operating - '||v_transaction_number,
    v_amount,v_reference
  );
  insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
  select v_destination_account_id,v_cheque_date,
    'Brokerage share received from Commission Trust - '||v_transaction_number,
    v_amount,false,v_reference
  where not exists(select 1 from public.dv_accounting_bank_transactions b where b.reference=v_reference and b.bank_account_id=v_destination_account_id);

  return jsonb_build_object('already_posted',false,'amount',v_amount,'reference',v_reference,'cheque_reference',v_cheque_reference);
end;
$function$;
revoke all on function public.dv_accounting_pay_our_brokerage(uuid) from public;
grant execute on function public.dv_accounting_pay_our_brokerage(uuid) to authenticated;
