-- Support commission funding split between Real Estate Trust and direct solicitor deposits to Commission Trust.
-- Direct solicitor receipts are posted as Commission Trust deposits with matching GL liability entries.
create or replace function public.dv_accounting_receive_solicitor_commission_funding(
 p_settlement_id uuid,
 p_amount numeric,
 p_payment_date date,
 p_payment_reference text,
 p_remitter_name text
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v public.dv_accounting_seller_settlements%rowtype;
 v_total numeric(14,2);
 v_re_available numeric(14,2);
 v_ct_available numeric(14,2);
 v_shortfall numeric(14,2);
 v_client_name text;
 v_existing public.dv_accounting_trust_transactions%rowtype;
 v_result jsonb;
 v_trust_id uuid;
 v_journal_id uuid;
 v_ct_gl uuid;
 v_liability_gl uuid;
begin
 if auth.uid() is null or not public.dv_accounting_has_permission_all_scope('banking.reconcile') then
  raise exception 'You do not have permission to record a solicitor commission deposit.';
 end if;
 if p_amount is null or p_amount<=0 then raise exception 'Deposit amount must be greater than zero.'; end if;
 if p_payment_date is null or nullif(trim(coalesce(p_payment_reference,'')),'') is null or nullif(trim(coalesce(p_remitter_name,'')),'') is null then
  raise exception 'Payment date, bank reference and solicitor/remitter name are required.';
 end if;
 select * into v from public.dv_accounting_seller_settlements where id=p_settlement_id for update;
 if not found then raise exception 'Seller / Landlord Settlement was not found.'; end if;
 if v.status not in ('SELLER_PROCEEDS_CALCULATED','SELLER_PAID') then
  raise exception 'Solicitor funding can only be recorded before the commission transfer is posted.';
 end if;
 if v.commission_trust_account_id is null then raise exception 'Select and save the Commission Trust account first.'; end if;
 if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=v.commission_trust_account_id and b.company_id=v.company_id and b.account_type='COMMISSION_TRUST') then
  raise exception 'The selected Commission Trust account is invalid for this company.';
 end if;
 v_total:=round(coalesce(v.listing_commission_amount,0)+coalesce(v.cooperating_commission_amount,0)+coalesce(v.commission_hst_amount,0),2);
 if v_total<=0 then raise exception 'The saved commission amount must be greater than zero.'; end if;
 select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0) into v_re_available
 from public.dv_accounting_trust_liabilities l
 where l.company_id=v.company_id and l.transaction_id=v.transaction_id and l.trust_account_type='REAL_ESTATE_TRUST';
 select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0) into v_ct_available
 from public.dv_accounting_trust_liabilities l
 where l.company_id=v.company_id and l.transaction_id=v.transaction_id and l.trust_account_type='COMMISSION_TRUST';
 v_shortfall:=greatest(0,round(v_total-coalesce(v_re_available,0)-coalesce(v_ct_available,0),2));
 if p_amount>v_shortfall+0.005 then
  raise exception 'Deposit exceeds the remaining commission funding shortfall of %.',to_char(v_shortfall,'FM999999990.00');
 end if;
 select client_name into v_client_name from public.dv_accounting_trust_liabilities
 where company_id=v.company_id and transaction_id=v.transaction_id and trust_account_type='REAL_ESTATE_TRUST'
 order by created_at asc limit 1;
 v_client_name:=coalesce(nullif(trim(v_client_name),''),nullif(trim(v.seller_client_name),''),'Seller commission funding');
 select * into v_existing from public.dv_accounting_trust_transactions
 where transaction_id=v.transaction_id and bank_account_id=v.commission_trust_account_id
  and trust_account_type='COMMISSION_TRUST' and direction='DEPOSIT' and reference=trim(p_payment_reference)
 limit 1;
 if found then
  if v_existing.amount=p_amount and v_existing.ledger_date=p_payment_date and v_existing.status='POSTED' then
   return jsonb_build_object('ok',true,'duplicate',true,'trust_transaction_id',v_existing.id,'amount',v_existing.amount);
  end if;
  raise exception 'This payment reference is already used for this trade. Check the existing trust receipt.';
 end if;
 v_result:=public.dv_accounting_post_trust_transaction(
  v.company_id,v.commission_trust_account_id,v.transaction_id,p_payment_date,
  'COMMISSION_TRUST','DEPOSIT',v_client_name,v.matter,
  'Solicitor direct commission funding received from '||trim(p_remitter_name)||' - '||v.matter,
  round(p_amount,2),trim(p_payment_reference));
 v_trust_id:=(v_result->>'trust_transaction_id')::uuid;
 if coalesce((v_result->>'duplicate')::boolean,false) then
  return jsonb_build_object('ok',true,'duplicate',true,'trust_transaction_id',v_trust_id,'amount',round(p_amount,2));
 end if;
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values(v.company_id,'2400','HST Payable','LIABILITY'),
       (v.company_id,'2300','Real Estate Trust Liabilities','LIABILITY'),
       (v.company_id,'1020','Commission Trust Bank','ASSET')
 on conflict(company_id,code) do nothing;
 select id into v_ct_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='1020';
 select id into v_liability_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2300';
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(v.company_id,p_payment_date,'SOLICITOR_COMMISSION_FUNDING',v_trust_id,
  'Solicitor direct commission funding - '||v.matter||' - '||trim(p_remitter_name))
 returning id into v_journal_id;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
 values(v_journal_id,v_ct_gl,round(p_amount,2),0),
       (v_journal_id,v_liability_gl,0,round(p_amount,2));
 return jsonb_build_object('ok',true,'duplicate',false,'trust_transaction_id',v_trust_id,
  'amount',round(p_amount,2),'payment_date',p_payment_date,'payment_reference',trim(p_payment_reference),
  'remitter_name',trim(p_remitter_name));
end;
$$;
revoke all on function public.dv_accounting_receive_solicitor_commission_funding(uuid,numeric,date,text,text) from public,anon;
grant execute on function public.dv_accounting_receive_solicitor_commission_funding(uuid,numeric,date,text,text) to authenticated;

create or replace function public.dv_accounting_process_seller_commission_transfer(
 p_settlement_id uuid,p_transfer_reference text,p_transfer_date date
) returns public.dv_accounting_seller_settlements
language plpgsql
set search_path=public
as $function$
declare
 v public.dv_accounting_seller_settlements%rowtype;
 v_total numeric(14,2);
 v_re_available numeric(14,2);
 v_ct_available numeric(14,2);
 v_re_transfer_amount numeric(14,2);
 v_bank_available numeric(14,2);
 v_trust_client_name text;
 v_seller_paid numeric(14,2);
 v_rev_gl uuid;
 v_hst_gl uuid;
 v_trust_liability_gl uuid;
 v_real_estate_bank_gl uuid;
 v_commission_bank_gl uuid;
 v_journal_id uuid;
 v_revenue_amount numeric(14,2);
begin
 select * into v from public.dv_accounting_seller_settlements where id=p_settlement_id for update;
 if not found then raise exception 'Seller settlement was not found.'; end if;
 if v.status not in ('SELLER_PROCEEDS_CALCULATED','SELLER_PAID') then
  raise exception 'Save and verify the seller settlement before transferring commissions.';
 end if;
 if v.real_estate_trust_account_id is null or v.commission_trust_account_id is null
  or v.real_estate_trust_account_id=v.commission_trust_account_id then
  raise exception 'Select two different trust accounts.';
 end if;
 if coalesce(nullif(trim(v.seller_client_name),''),'')='' or coalesce(nullif(trim(v.matter),''),'')='' then
  raise exception 'Seller/client name and trade number are required for the trust ledger.';
 end if;
 v_total:=round(coalesce(v.listing_commission_amount,0)+coalesce(v.cooperating_commission_amount,0)+coalesce(v.commission_hst_amount,0),2);
 if v_total<=0 then raise exception 'Commission transfer must be greater than zero.'; end if;
 if coalesce(nullif(trim(p_transfer_reference),''),'')='' or p_transfer_date is null then
  raise exception 'Transfer reference and date are required.';
 end if;
 if not exists(select 1 from public.dv_accounting_bank_accounts where id=v.real_estate_trust_account_id and company_id=v.company_id and account_type='REAL_ESTATE_TRUST') then
  raise exception 'The selected Real Estate Trust account does not belong to this company.';
 end if;
 if not exists(select 1 from public.dv_accounting_bank_accounts where id=v.commission_trust_account_id and company_id=v.company_id and account_type='COMMISSION_TRUST') then
  raise exception 'The selected Commission Trust account does not belong to this company.';
 end if;
 select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0) into v_re_available
 from public.dv_accounting_trust_liabilities l where l.company_id=v.company_id and l.transaction_id=v.transaction_id
  and l.trust_account_type='REAL_ESTATE_TRUST' and l.matter=v.matter;
 select coalesce(sum(case when l.direction='RECEIVABLE' then l.amount else -l.amount end),0) into v_ct_available
 from public.dv_accounting_trust_liabilities l where l.company_id=v.company_id and l.transaction_id=v.transaction_id
  and l.trust_account_type='COMMISSION_TRUST' and l.matter=v.matter;
 if coalesce(v_re_available,0)+coalesce(v_ct_available,0)+0.005<v_total then
  raise exception 'Commission funding is short by %. Record the seller solicitor direct deposit into Commission Trust before posting.',
   to_char(v_total-coalesce(v_re_available,0)-coalesce(v_ct_available,0),'FM999999990.00');
 end if;
 v_re_transfer_amount:=greatest(0,round(v_total-coalesce(v_ct_available,0),2));
 select coalesce(sum(p.amount),0) into v_seller_paid
 from public.dv_accounting_seller_settlement_payments p
 where p.settlement_id=v.id and upper(coalesce(p.status,''))='COMPLETED'
  and p.trust_transaction_id is not null
  and (upper(coalesce(p.payee_type,'')) in ('SELLER','LANDLORD') or nullif(trim(coalesce(p.direction_storage_path,'')),'') is not null);
 if greatest(0,round(coalesce(v.seller_proceeds_amount,0)-coalesce(v_seller_paid,0),2))>0.009 then
  raise exception 'Seller/landlord proceeds remain unpaid. Complete and post those payments before transferring commission.';
 end if;
 if v_re_transfer_amount>0 then
  select coalesce(ba.opening_balance,0)+coalesce(sum(bt.amount),0) into v_bank_available
  from public.dv_accounting_bank_accounts ba left join public.dv_accounting_bank_transactions bt on bt.bank_account_id=ba.id
  where ba.id=v.real_estate_trust_account_id and ba.company_id=v.company_id group by ba.id,ba.opening_balance;
  if not found or coalesce(v_bank_available,0)+0.005<v_re_transfer_amount then
   raise exception 'Insufficient available Real Estate Trust bank balance for the remaining % transfer.',to_char(v_re_transfer_amount,'FM999999990.00');
  end if;
  select client_name into v_trust_client_name from public.dv_accounting_trust_liabilities
  where company_id=v.company_id and transaction_id=v.transaction_id and trust_account_type='REAL_ESTATE_TRUST' and matter=v.matter
  order by created_at asc limit 1;
  v_trust_client_name:=coalesce(nullif(trim(v_trust_client_name),''),nullif(trim(v.seller_client_name),''),'Seller commission funding');
  perform public.dv_accounting_post_trust_transaction(
   p_company_id=>v.company_id,p_bank_account_id=>v.real_estate_trust_account_id,p_transaction_id=>v.transaction_id,
   p_ledger_date=>p_transfer_date,p_trust_account_type=>'REAL_ESTATE_TRUST',p_direction=>'DISBURSEMENT',
   p_client_name=>v_trust_client_name,p_matter=>v.matter,p_description=>'Commission transfer to Commission Trust - '||v.matter,
   p_amount=>v_re_transfer_amount,p_reference=>trim(p_transfer_reference)||'-OUT');
  perform public.dv_accounting_post_trust_transaction(
   p_company_id=>v.company_id,p_bank_account_id=>v.commission_trust_account_id,p_transaction_id=>v.transaction_id,
   p_ledger_date=>p_transfer_date,p_trust_account_type=>'COMMISSION_TRUST',p_direction=>'DEPOSIT',
   p_client_name=>v_trust_client_name,p_matter=>v.matter,p_description=>'Commission transfer received from Real Estate Trust - '||v.matter,
   p_amount=>v_re_transfer_amount,p_reference=>trim(p_transfer_reference)||'-IN');
 end if;
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values(v.company_id,'4000','Commission Revenue','REVENUE'),(v.company_id,'2400','HST Payable','LIABILITY'),
  (v.company_id,'2300','Real Estate Trust Liabilities','LIABILITY'),(v.company_id,'1015','Real Estate Trust Bank','ASSET'),
  (v.company_id,'1020','Commission Trust Bank','ASSET')
 on conflict(company_id,code) do nothing;
 select id into v_rev_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='4000';
 select id into v_hst_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2400';
 select id into v_trust_liability_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='2300';
 select id into v_real_estate_bank_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='1015';
 select id into v_commission_bank_gl from public.dv_accounting_gl_accounts where company_id=v.company_id and code='1020';
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(v.company_id,p_transfer_date,'SELLER_COMMISSION_TRANSFER',v.id,'Recognize listing-side commission on trust transfer')
 returning id into v_journal_id;
 if v_re_transfer_amount>0 then
  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(v_journal_id,v_commission_bank_gl,v_re_transfer_amount,0),
        (v_journal_id,v_real_estate_bank_gl,0,v_re_transfer_amount);
 end if;
 v_revenue_amount:=round(coalesce(v.listing_commission_amount,0)+coalesce(v.cooperating_commission_amount,0),2);
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
 values(v_journal_id,v_trust_liability_gl,v_total,0);
 if v_revenue_amount>0 then
  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(v_journal_id,v_rev_gl,0,v_revenue_amount);
 end if;
 if coalesce(v.commission_hst_amount,0)>0 then
  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(v_journal_id,v_hst_gl,0,round(v.commission_hst_amount,2));
 end if;
 update public.dv_accounting_seller_settlements
 set status='READY_FOR_COMMISSION_PAYROLL',commission_transfer_amount=v_total,
  commission_transfer_reference=trim(p_transfer_reference),commission_transfer_date=p_transfer_date,
  updated_at=now(),updated_by=auth.uid()
 where id=p_settlement_id returning * into v;
 return v;
end;
$function$;
