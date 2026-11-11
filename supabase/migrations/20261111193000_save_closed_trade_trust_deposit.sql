-- Allow an authorized trust-account correction on closed transactions without unlocking the trade.
create or replace function public.dv_accounting_save_transaction_trust_deposit(
 p_transaction_id uuid,
 p_we_hold_deposit text,
 p_held_by text,
 p_received text,
 p_deposit_date date,
 p_received_from text,
 p_amount numeric,
 p_trust_bank_account_id uuid,
 p_earns_interest text,
 p_payment_type text,
 p_reference_number text
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
 v_tx public.dv_accounting_transactions%rowtype;
 v_existing public.dv_accounting_transaction_trust%rowtype;
 v_bank public.dv_accounting_bank_accounts%rowtype;
 v_trust_result jsonb;
 v_posted_id uuid;
 v_duplicate boolean:=false;
begin
 if auth.uid() is null then raise exception 'Please sign in again before saving trust deposit details.'; end if;
 if public.dv_accounting_current_user_role()<>'SUPERADMIN'
    and not public.dv_accounting_has_permission_all_scope('banking.reconcile') then
  raise exception 'You need trust reconciliation permission to correct a deposit on a closed transaction.';
 end if;
 select * into v_tx from public.dv_accounting_transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found.'; end if;
 if upper(coalesce(p_we_hold_deposit,'')) not in ('YES','NO') or upper(coalesce(p_received,'')) not in ('YES','NO') then
  raise exception 'Choose whether Dream Valley holds the deposit and whether it has been received.';
 end if;
 if coalesce(p_amount,0)<0 then raise exception 'Deposit amount cannot be negative.'; end if;
 if p_we_hold_deposit='YES' and p_received='YES' and coalesce(p_amount,0)>0 then
  if p_trust_bank_account_id is null then raise exception 'Select the Dream Valley Real Estate Trust bank account.'; end if;
  if nullif(trim(coalesce(p_received_from,'')),'') is null then raise exception 'Enter who paid the deposit.'; end if;
  if p_deposit_date is null then raise exception 'Enter the actual deposit date.'; end if;
  select * into v_bank from public.dv_accounting_bank_accounts
   where id=p_trust_bank_account_id and company_id=v_tx.company_id and account_type='REAL_ESTATE_TRUST' and active=true;
  if not found then raise exception 'Selected bank account is not an active Real Estate Trust account for this company.'; end if;
 else
  v_bank:=null;
 end if;
 select * into v_existing from public.dv_accounting_transaction_trust where transaction_id=p_transaction_id for update;
 if found then
  update public.dv_accounting_transaction_trust set
   we_hold_deposit=p_we_hold_deposit,
   held_by=coalesce(nullif(trim(p_held_by),''),case when p_we_hold_deposit='YES' then 'Dream Valley Realty Inc., Brokerage' else null end),
   received=p_received,deposit_date=p_deposit_date,received_from=nullif(trim(p_received_from),''),
   amount=coalesce(p_amount,0),trust_bank_account_id=case when p_we_hold_deposit='YES' then p_trust_bank_account_id else null end,
   earns_interest=coalesce(p_earns_interest,'NO'),payment_type=coalesce(p_payment_type,'CHEQUE'),
   reference_number=nullif(trim(p_reference_number),'')
   where id=v_existing.id;
 else
  insert into public.dv_accounting_transaction_trust(
   transaction_id,we_hold_deposit,held_by,received,deposit_date,received_from,amount,
   trust_bank_account_id,earns_interest,payment_type,reference_number
  ) values(
   p_transaction_id,p_we_hold_deposit,
   coalesce(nullif(trim(p_held_by),''),case when p_we_hold_deposit='YES' then 'Dream Valley Realty Inc., Brokerage' else null end),
   p_received,p_deposit_date,nullif(trim(p_received_from),''),coalesce(p_amount,0),
   case when p_we_hold_deposit='YES' then p_trust_bank_account_id else null end,
   coalesce(p_earns_interest,'NO'),coalesce(p_payment_type,'CHEQUE'),nullif(trim(p_reference_number),'')
  );
 end if;
 if p_we_hold_deposit='YES' and p_received='YES' and coalesce(p_amount,0)>0 then
  select id into v_posted_id from public.dv_accounting_trust_transactions
   where transaction_id=p_transaction_id and bank_account_id=p_trust_bank_account_id
    and trust_account_type='REAL_ESTATE_TRUST' and direction='DEPOSIT' and status='POSTED'
    and amount=round(p_amount,2) and ledger_date=p_deposit_date
    and coalesce(reference,'')=coalesce(nullif(trim(p_reference_number),''),'')
   order by created_at limit 1;
  if v_posted_id is null then
   if exists(select 1 from public.dv_accounting_trust_transactions
    where transaction_id=p_transaction_id and trust_account_type='REAL_ESTATE_TRUST'
     and direction='DEPOSIT' and status='POSTED'
     and (coalesce(reference,'')=coalesce(nullif(trim(p_reference_number),''),'') or
       (bank_account_id=p_trust_bank_account_id and ledger_date=p_deposit_date and amount=round(p_amount,2)))) then
    raise exception 'A similar trust deposit already exists with different details. Review the trust ledger before saving to avoid a duplicate.';
   end if;
   v_trust_result:=public.dv_accounting_post_trust_transaction(
    v_tx.company_id,p_trust_bank_account_id,p_transaction_id,p_deposit_date,
    'REAL_ESTATE_TRUST','DEPOSIT',nullif(trim(p_received_from),''),v_tx.transaction_number,
    'Deposit received and held by Dream Valley for trade '||v_tx.transaction_number,
    round(p_amount,2),nullif(trim(p_reference_number),'')
   );
   v_posted_id:=(v_trust_result->>'trust_transaction_id')::uuid;
   v_duplicate:=coalesce((v_trust_result->>'duplicate')::boolean,false);
  else
   v_duplicate:=true;
  end if;
 end if;
 return jsonb_build_object('ok',true,'transaction_id',p_transaction_id,
  'trust_transaction_id',v_posted_id,'ledger_posted',v_posted_id is not null,
  'duplicate',v_duplicate,'message',case when v_posted_id is not null then 'Trust deposit details saved and the matching trust ledger receipt is confirmed.' else 'Trust deposit details saved. No Dream Valley trust receipt was posted because the deposit is not held by Dream Valley or has not been received.' end);
end;
$$;
revoke all on function public.dv_accounting_save_transaction_trust_deposit(uuid,text,text,text,date,text,numeric,uuid,text,text,text) from public,anon;
grant execute on function public.dv_accounting_save_transaction_trust_deposit(uuid,text,text,text,date,text,numeric,uuid,text,text,text) to authenticated;
