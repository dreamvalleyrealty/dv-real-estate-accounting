-- Keep commission-trust ledger, bank book and client/matter liabilities in sync for every issued agent cheque.
create or replace function public.dv_accounting_post_commission_cheque_to_trust()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_company_id uuid;
  v_bank_account_id uuid;
  v_transaction_id uuid;
  v_transaction_number text;
  v_client_name text;
  v_reference text;
  v_existing_trust_id uuid;
begin
  if upper(coalesce(new.status,'')) <> 'ISSUED' then return new; end if;
  select t.company_id,t.id,t.transaction_number into v_company_id,v_transaction_id,v_transaction_number
  from public.dv_accounting_transactions t
  where t.id=(select c.transaction_id from public.dv_accounting_commissions c where c.id=new.commission_id);
  if v_company_id is null or v_transaction_id is null then
    raise exception 'Cannot issue commission payment: linked transaction/company was not found.';
  end if;
  v_reference := 'COMMISSION-CHEQUE:'||new.id::text;
  select x.id into v_existing_trust_id from public.dv_accounting_trust_transactions x
  where x.reference=v_reference and x.trust_account_type='COMMISSION_TRUST' limit 1;
  if v_existing_trust_id is not null then
    select d.bank_account_id,d.client_name into v_bank_account_id,v_client_name
    from public.dv_accounting_trust_transactions d
    where d.transaction_id=v_transaction_id and d.trust_account_type='COMMISSION_TRUST'
      and d.direction='DEPOSIT' and d.status='POSTED'
    order by d.created_at desc limit 1;
    if v_bank_account_id is not null then
      if not exists(select 1 from public.dv_accounting_bank_transactions b where b.reference=v_reference) then
        insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
        values(v_bank_account_id,coalesce(new.cheque_date,current_date),
          'Commission payment to agent '||coalesce(new.payment_reference,new.cheque_number,'')||' for '||v_transaction_number,
          -coalesce(new.net_amount,0),false,v_reference);
      end if;
      if not exists(select 1 from public.dv_accounting_trust_liabilities l where l.trust_transaction_id=v_existing_trust_id) then
        insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
        values(v_company_id,v_existing_trust_id,v_transaction_id,'COMMISSION_TRUST',v_client_name,v_transaction_number,coalesce(new.net_amount,0),'RELEASED');
      end if;
    end if;
    return new;
  end if;
  select d.bank_account_id,d.client_name into v_bank_account_id,v_client_name
  from public.dv_accounting_trust_transactions d
  where d.company_id=v_company_id and d.transaction_id=v_transaction_id
    and d.trust_account_type='COMMISSION_TRUST' and d.direction='DEPOSIT' and d.status='POSTED'
  order by d.created_at desc limit 1;
  if v_bank_account_id is null then
    raise exception 'Cannot issue commission payment: no posted Commission Trust deposit exists for trade %.',v_transaction_number;
  end if;
  if coalesce(new.net_amount,0)<=0 then
    raise exception 'Cannot issue commission payment: cheque net amount must be greater than zero.';
  end if;
  perform public.dv_accounting_post_trust_transaction(
    v_company_id,v_bank_account_id,v_transaction_id,coalesce(new.cheque_date,current_date),
    'COMMISSION_TRUST','DISBURSEMENT',v_client_name,v_transaction_number,
    'Commission payment to agent '||coalesce(new.payment_reference,new.cheque_number,'')||' for '||v_transaction_number,
    new.net_amount,v_reference
  );
  return new;
end;
$function$;

-- Repair the already-issued EFT290 payout: it had a trust-ledger row but no bank-book entry or liability release.
do $repair$
declare v_cheque record; v_disbursement record; v_deposit record;
begin
  select q.id,q.company_id,q.agent_id,q.commission_id,q.cheque_number,q.cheque_date,q.net_amount,q.payment_reference,c.transaction_id,t.transaction_number
    into v_cheque
  from public.dv_accounting_commission_cheques q
  join public.dv_accounting_commissions c on c.id=q.commission_id
  join public.dv_accounting_transactions t on t.id=c.transaction_id
  where q.cheque_number='EFT290' and t.transaction_number='TR26101401'
  order by q.created_at desc limit 1;
  if v_cheque.id is null then raise notice 'EFT290 / TR26101401 not found; no historical repair required.'; return; end if;
  select * into v_disbursement from public.dv_accounting_trust_transactions
  where reference='COMMISSION-CHEQUE:'||v_cheque.id::text and trust_account_type='COMMISSION_TRUST' limit 1;
  if v_disbursement.id is null then raise exception 'EFT290 trust disbursement is missing; refusing to fabricate a historical payout.'; end if;
  select * into v_deposit from public.dv_accounting_trust_transactions
  where transaction_id=v_cheque.transaction_id and trust_account_type='COMMISSION_TRUST'
    and direction='DEPOSIT' and status='POSTED' order by created_at desc limit 1;
  if v_deposit.id is null then raise exception 'EFT290 matching Commission Trust deposit is missing; no historical repair completed.'; end if;
  update public.dv_accounting_trust_transactions set client_name=v_deposit.client_name,matter=v_cheque.transaction_number where id=v_disbursement.id;
  if not exists(select 1 from public.dv_accounting_bank_transactions where reference='COMMISSION-CHEQUE:'||v_cheque.id::text) then
    insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
    values(v_deposit.bank_account_id,v_cheque.cheque_date,
      'Commission payment to agent '||coalesce(v_cheque.payment_reference,v_cheque.cheque_number,'')||' for '||v_cheque.transaction_number,
      -v_cheque.net_amount,false,'COMMISSION-CHEQUE:'||v_cheque.id::text);
  end if;
  if not exists(select 1 from public.dv_accounting_trust_liabilities where trust_transaction_id=v_disbursement.id) then
    insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
    values(v_disbursement.company_id,v_disbursement.id,v_cheque.transaction_id,'COMMISSION_TRUST',
      v_deposit.client_name,v_cheque.transaction_number,v_cheque.net_amount,'RELEASED');
  end if;
end;
$repair$;