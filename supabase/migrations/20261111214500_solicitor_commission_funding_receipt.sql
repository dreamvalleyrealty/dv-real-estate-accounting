create or replace function public.dv_accounting_receive_solicitor_commission_funding(
 p_settlement_id uuid,
 p_amount numeric,
 p_payment_date date,
 p_payment_reference text,
 p_remitter_name text
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $function$
declare
 v_settlement public.dv_accounting_seller_settlements%rowtype;
 v_transaction public.dv_accounting_transactions%rowtype;
 v_bank public.dv_accounting_bank_accounts%rowtype;
 v_real_estate_balance numeric := 0;
 v_commission_balance numeric := 0;
 v_required numeric := 0;
 v_shortfall numeric := 0;
 v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication is required to record solicitor commission funding'; end if;
 if not public.dv_accounting_has_permission('transactions.edit') and not public.dv_accounting_has_permission('banking.reconcile') then
  raise exception 'You do not have permission to record trust funding';
 end if;
 if p_amount is null or p_amount <= 0 then raise exception 'Deposit amount must be greater than zero'; end if;
 if p_payment_date is null then raise exception 'Deposit date is required'; end if;
 if nullif(trim(coalesce(p_remitter_name,'')),'') is null then raise exception 'Seller solicitor / remitter is required'; end if;
 if nullif(trim(coalesce(p_payment_reference,'')),'') is null or upper(trim(p_payment_reference)) !~ '^(CHEQUE|EFT):[[:space:]]*.+$' then
  raise exception 'Enter a cheque number or EFT reference and select the payment method';
 end if;
 select * into v_settlement from public.dv_accounting_seller_settlements where id=p_settlement_id for update;
 if not found then raise exception 'Seller / Landlord Settlement was not found'; end if;
 if upper(coalesce(v_settlement.status,'')) in ('READY_FOR_COMMISSION_PAYROLL','COMMISSION_PAYROLL_PROCESSED','PAYMENTS_COMPLETED') then
  raise exception 'Commission funding is already posted for this settlement';
 end if;
 if v_settlement.commission_trust_account_id is null then
  raise exception 'Save the Commission Trust account in Transfer Details before recording the solicitor deposit';
 end if;
 select * into v_transaction from public.dv_accounting_transactions where id=v_settlement.transaction_id;
 if not found then raise exception 'Linked transaction was not found'; end if;
 select * into v_bank from public.dv_accounting_bank_accounts where id=v_settlement.commission_trust_account_id and company_id=v_settlement.company_id;
 if not found or v_bank.account_type <> 'COMMISSION_TRUST' then raise exception 'The saved destination is not a valid Commission Trust bank account'; end if;
 v_required := round(coalesce(v_settlement.listing_commission_amount,0)+coalesce(v_settlement.cooperating_commission_amount,0)+coalesce(v_settlement.commission_hst_amount,0),2);
 select coalesce(sum(case when direction='RECEIVABLE' then amount else -amount end),0) into v_real_estate_balance
 from public.dv_accounting_trust_liabilities where transaction_id=v_settlement.transaction_id and trust_account_type='REAL_ESTATE_TRUST';
 select coalesce(sum(case when direction='RECEIVABLE' then amount else -amount end),0) into v_commission_balance
 from public.dv_accounting_trust_liabilities where transaction_id=v_settlement.transaction_id and trust_account_type='COMMISSION_TRUST';
 v_shortfall := greatest(0,round(v_required-v_real_estate_balance-v_commission_balance,2));
 if v_shortfall <= 0 then raise exception 'There is no remaining commission funding shortfall'; end if;
 if p_amount > v_shortfall then raise exception 'Deposit exceeds the remaining commission funding shortfall of %',to_char(v_shortfall,'FM999,999,990.00'); end if;
 select public.dv_accounting_post_trust_transaction(
  p_company_id=>v_settlement.company_id,
  p_bank_account_id=>v_bank.id,
  p_transaction_id=>v_settlement.transaction_id,
  p_ledger_date=>p_payment_date,
  p_trust_account_type=>'COMMISSION_TRUST',
  p_direction=>'DEPOSIT',
  p_client_name=>coalesce(nullif(trim(v_settlement.seller_client_name),''),nullif(trim(v_transaction.client_name),''),v_transaction.property_address,'Commission funding'),
  p_matter=>coalesce(nullif(trim(v_settlement.matter),''),v_transaction.transaction_number),
  p_description=>'Solicitor direct commission funding received from '||trim(p_remitter_name)||' - '||coalesce(v_settlement.matter,v_transaction.transaction_number),
  p_amount=>round(p_amount,2),
  p_reference=>upper(split_part(trim(p_payment_reference),':',1))||': '||trim(substr(trim(p_payment_reference),position(':' in trim(p_payment_reference))+1))
 ) into v_result;
 return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('ok',true,'settlement_id',v_settlement.id,'transaction_id',v_settlement.transaction_id,'payment_method',upper(split_part(trim(p_payment_reference),':',1)),'remaining_shortfall',greatest(0,round(v_shortfall-p_amount,2)));
end;
$function$;
revoke all on function public.dv_accounting_receive_solicitor_commission_funding(uuid,numeric,date,text,text) from public,anon;
grant execute on function public.dv_accounting_receive_solicitor_commission_funding(uuid,numeric,date,text,text) to authenticated;
