create or replace function public.dv_accounting_correct_rejected_listing_deposit(
  p_trust_transaction_id uuid,
  p_amount numeric,
  p_ledger_date date,
  p_bank_account_id uuid,
  p_client_name text,
  p_reference text default null,
  p_payment_type text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text := public.dv_accounting_current_user_role();
  v_ledger public.dv_accounting_trust_transactions%rowtype;
  v_bank_tx public.dv_accounting_bank_transactions%rowtype;
  v_issuance public.dv_accounting_deposit_receipt_issuances%rowtype;
  v_account_type text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if v_role not in ('ADMIN','SUPERADMIN') then raise exception 'Only an Admin or Super Admin can correct a rejected deposit'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Corrected deposit amount must be greater than zero'; end if;
  if p_ledger_date is null or nullif(trim(coalesce(p_client_name,'')),'') is null then raise exception 'Date and payer are required'; end if;

  select * into v_ledger from public.dv_accounting_trust_transactions
  where id=p_trust_transaction_id and trust_account_type='REAL_ESTATE_TRUST' and direction='DEPOSIT' and status='POSTED' for update;
  if not found then raise exception 'Posted Real Estate Trust deposit not found'; end if;

  select * into v_issuance from public.dv_accounting_deposit_receipt_issuances where trust_transaction_id=v_ledger.id for update;
  if not found or v_issuance.approval_status <> 'REJECTED' then raise exception 'Only a rejected deposit receipt can be corrected through this workflow'; end if;

  select account_type into v_account_type from public.dv_accounting_bank_accounts where id=p_bank_account_id and active=true for share;
  if v_account_type is distinct from 'REAL_ESTATE_TRUST' then raise exception 'Select an active Real Estate Trust bank account'; end if;

  select * into v_bank_tx from public.dv_accounting_bank_transactions where trust_transaction_id=v_ledger.id for update;
  if not found then raise exception 'Matching bank transaction was not found; no correction was made'; end if;
  if coalesce(v_bank_tx.reconciled,false) then raise exception 'This bank transaction has already been reconciled. Reopen or correct the reconciliation before changing this deposit'; end if;

  update public.dv_accounting_trust_transactions set amount=p_amount,ledger_date=p_ledger_date,bank_account_id=p_bank_account_id,client_name=trim(p_client_name),reference=nullif(trim(coalesce(p_reference,'')),'') where id=v_ledger.id;
  update public.dv_accounting_bank_transactions set amount=p_amount,transaction_date=p_ledger_date,bank_account_id=p_bank_account_id,description='Deposit received for listing '||coalesce(v_ledger.matter,v_ledger.transaction_id::text),reference=nullif(trim(coalesce(p_reference,'')),'') where id=v_bank_tx.id;
  update public.dv_accounting_trust_liabilities set amount=p_amount,client_name=trim(p_client_name) where trust_transaction_id=v_ledger.id;
  update public.dv_accounting_transaction_trust set amount=p_amount,deposit_date=p_ledger_date,trust_bank_account_id=p_bank_account_id,received_from=trim(p_client_name),reference_number=nullif(trim(coalesce(p_reference,'')),''),payment_type=coalesce(nullif(trim(coalesce(p_payment_type,'')),''),payment_type) where transaction_id=v_ledger.transaction_id;
  update public.dv_accounting_transactions set deposit_amount=p_amount,trust_bank_account_id=p_bank_account_id where id=v_ledger.transaction_id;
  update public.dv_accounting_deposit_receipt_issuances set approval_status='PENDING',approved_by=null,approved_at=null,rejection_reason=null where id=v_issuance.id;
  return jsonb_build_object('ok',true,'approval_status','PENDING','message','Rejected deposit corrected in the trust ledger and returned to Pending Approval.');
end;
$$;
revoke all on function public.dv_accounting_correct_rejected_listing_deposit(uuid,numeric,date,uuid,text,text,text) from public;
grant execute on function public.dv_accounting_correct_rejected_listing_deposit(uuid,numeric,date,uuid,text,text,text) to authenticated;
