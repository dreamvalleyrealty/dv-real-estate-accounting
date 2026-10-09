-- Complete trust posting: create bank activity and prevent over-release
create or replace function public.dv_accounting_post_trust_transaction(
 p_company_id uuid,p_bank_account_id uuid,p_transaction_id uuid,p_ledger_date date,
 p_trust_account_type text,p_direction text,p_client_name text,p_matter text,
 p_description text,p_amount numeric,p_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare tt uuid; li uuid; company uuid; bank_type text; available numeric;
begin
 if p_amount is null or p_amount<=0 then raise exception 'Trust amount must be greater than zero'; end if;
 if p_direction not in ('DEPOSIT','DISBURSEMENT') then raise exception 'Invalid trust direction'; end if;
 select account_type into bank_type from public.dv_accounting_bank_accounts where id=p_bank_account_id;
 if bank_type is null then raise exception 'Trust bank account not found'; end if;
 if bank_type<>p_trust_account_type then raise exception 'Bank account type does not match trust account type'; end if;
 company:=coalesce(p_company_id,(select company_id from public.dv_accounting_bank_accounts where id=p_bank_account_id));
 if p_direction='DISBURSEMENT' then
   select coalesce(sum(case when direction='RECEIVABLE' then amount else -amount end),0) into available
   from public.dv_accounting_trust_liabilities
   where company_id=company and trust_account_type=p_trust_account_type
     and coalesce(client_name,'')=coalesce(p_client_name,'')
     and coalesce(matter,'')=coalesce(p_matter,'');
   if available < p_amount then raise exception 'Disbursement exceeds available trust liability for this client/matter'; end if;
 end if;
 insert into public.dv_accounting_trust_transactions(company_id,bank_account_id,transaction_id,ledger_date,trust_account_type,direction,client_name,matter,description,amount,reference)
 values(company,p_bank_account_id,p_transaction_id,coalesce(p_ledger_date,current_date),p_trust_account_type,p_direction,p_client_name,p_matter,p_description,p_amount,p_reference)
 returning id into tt;
 insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
 values(company,tt,p_transaction_id,p_trust_account_type,p_client_name,p_matter,p_amount,case when p_direction='DEPOSIT' then 'RECEIVABLE' else 'RELEASED' end)
 returning id into li;
 insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
 values(p_bank_account_id,coalesce(p_ledger_date,current_date),p_description,
   case when p_direction='DEPOSIT' then p_amount else -p_amount end,false,p_reference);
 return jsonb_build_object('ok',true,'trust_transaction_id',tt,'liability_id',li);
end $$;
