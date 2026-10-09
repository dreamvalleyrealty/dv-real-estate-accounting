-- Automatically connect finalized transactions to trust accounting when a trust deposit is recorded
alter table public.dv_accounting_transactions add column if not exists trust_bank_account_id uuid references public.dv_accounting_bank_accounts(id);

create or replace function public.dv_accounting_finalize_transaction(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 t public.dv_accounting_transactions%rowtype;
 company uuid; je uuid; ar uuid; rev uuid; hst uuid; agent_exp uuid; agent_pay uuid;
 agent_amt numeric(14,2); trust_id uuid; trust_bank uuid; trust_type text;
begin
 select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if t.status='FINALIZED' then return jsonb_build_object('ok',true,'message','Already finalized'); end if;
 company:=t.company_id;
 if company is null then
   select id into company from public.dv_accounting_companies order by created_at limit 1;
   if company is null then raise exception 'Create a company in Settings before finalizing transactions'; end if;
   update public.dv_accounting_transactions set company_id=company where id=t.id;
 end if;

 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values
 (company,'1150','Commission Receivable','ASSET'),
 (company,'4000','Commission Revenue','REVENUE'),
 (company,'2400','HST Payable','LIABILITY'),
 (company,'5200','Agent Commission Expense','EXPENSE'),
 (company,'2200','Agent Commissions Payable','LIABILITY')
 on conflict(company_id,code) do nothing;
 select id into ar from public.dv_accounting_gl_accounts where company_id=company and code='1150';
 select id into rev from public.dv_accounting_gl_accounts where company_id=company and code='4000';
 select id into hst from public.dv_accounting_gl_accounts where company_id=company and code='2400';
 select id into agent_exp from public.dv_accounting_gl_accounts where company_id=company and code='5200';
 select id into agent_pay from public.dv_accounting_gl_accounts where company_id=company and code='2200';

 agent_amt:=coalesce(t.agent_commission,0);
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(company,coalesce(t.transaction_date,current_date),'TRANSACTION',t.id,'Finalize real estate transaction') returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
 values(je,ar,coalesce(t.gross_commission,0)+coalesce(t.hst_amount,0),0),(je,rev,0,coalesce(t.gross_commission,0));
 if coalesce(t.hst_amount,0)<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,hst,0,t.hst_amount);
 end if;
 if agent_amt<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,agent_exp,agent_amt,0),(je,agent_pay,0,agent_amt);
 end if;

 -- A deposit is trust money, never brokerage revenue or HST.
 if coalesce(t.deposit_amount,0)>0 then
   trust_type:=coalesce(t.trust_account_type,'REAL_ESTATE_TRUST');
   trust_bank:=t.trust_bank_account_id;
   if trust_bank is null then
     select id into trust_bank from public.dv_accounting_bank_accounts
     where company_id=company and account_type=trust_type order by created_at limit 1;
   end if;
   if trust_bank is null then raise exception 'Set up a % bank account before finalizing a transaction with a trust deposit',trust_type; end if;
   if not exists(select 1 from public.dv_accounting_bank_accounts where id=trust_bank and company_id=company and account_type=trust_type)
     then raise exception 'Selected trust bank account does not match the transaction trust account type'; end if;

   insert into public.dv_accounting_trust_transactions(company_id,bank_account_id,transaction_id,ledger_date,trust_account_type,direction,client_name,matter,description,amount,reference)
   values(company,trust_bank,t.id,coalesce(t.transaction_date,current_date),trust_type,'DEPOSIT',t.client_name,t.property_address,'Trust deposit received',t.deposit_amount,t.transaction_number)
   returning id into trust_id;
   insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
   values(company,trust_id,t.id,trust_type,t.client_name,t.property_address,t.deposit_amount,'RECEIVABLE');
   insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
   values(trust_bank,coalesce(t.transaction_date,current_date),'Trust deposit - '||coalesce(t.client_name,t.property_address,'Transaction'),t.deposit_amount,false,t.transaction_number);
 end if;

 update public.dv_accounting_transactions set status='FINALIZED',finalized_at=now(),company_id=company,trust_bank_account_id=trust_bank where id=t.id;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'agent_commission',agent_amt,'trust_transaction_id',trust_id);
end $$;

revoke all on function public.dv_accounting_finalize_transaction(uuid) from public;
grant execute on function public.dv_accounting_finalize_transaction(uuid) to authenticated;
