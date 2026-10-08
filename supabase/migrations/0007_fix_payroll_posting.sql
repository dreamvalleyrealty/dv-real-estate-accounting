-- Fix payroll remittance insertion to work with the partial unique index
create or replace function public.dv_accounting_post_payroll(p_payroll_run_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 r public.dv_accounting_payroll_runs%rowtype;
 company uuid;
 je uuid;
 wages uuid; employer_tax uuid; income_tax_payable uuid; cpp_payable uuid; cpp2_payable uuid; ei_payable uuid; net_payable uuid;
 due date;
 remitter text;
 total_remit numeric(14,2);
begin
 select * into r from public.dv_accounting_payroll_runs where id=p_payroll_run_id for update;
 if not found then raise exception 'Payroll run not found'; end if;
 if r.status='POSTED' then return jsonb_build_object('ok',true,'message','Payroll already posted','journal_entry_id',r.journal_entry_id); end if;
 if r.status not in ('CALCULATED','APPROVED') then raise exception 'Payroll must be calculated or approved before posting'; end if;

 company:=r.company_id;
 if company is null then
   select id into company from public.dv_accounting_companies order by created_at limit 1;
   if company is null then raise exception 'Create a company in Settings before posting payroll'; end if;
   update public.dv_accounting_payroll_runs set company_id=company where id=r.id;
 end if;

 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values
 (company,'5100','Salaries & Wages Expense','EXPENSE'),
 (company,'5110','Employer Payroll Tax Expense','EXPENSE'),
 (company,'2100','Income Tax Payable','LIABILITY'),
 (company,'2110','CPP Payable','LIABILITY'),
 (company,'2115','CPP2 Payable','LIABILITY'),
 (company,'2120','EI Payable','LIABILITY'),
 (company,'2150','Net Payroll Payable','LIABILITY')
 on conflict(company_id,code) do nothing;

 select id into wages from public.dv_accounting_gl_accounts where company_id=company and code='5100';
 select id into employer_tax from public.dv_accounting_gl_accounts where company_id=company and code='5110';
 select id into income_tax_payable from public.dv_accounting_gl_accounts where company_id=company and code='2100';
 select id into cpp_payable from public.dv_accounting_gl_accounts where company_id=company and code='2110';
 select id into cpp2_payable from public.dv_accounting_gl_accounts where company_id=company and code='2115';
 select id into ei_payable from public.dv_accounting_gl_accounts where company_id=company and code='2120';
 select id into net_payable from public.dv_accounting_gl_accounts where company_id=company and code='2150';

 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(company,coalesce(r.pay_date,r.period_end,current_date),'PAYROLL',r.id,'Post payroll accrual') returning id into je;

 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
 values
 (je,wages,coalesce(r.gross_pay,0),0),
 (je,employer_tax,coalesce(r.employer_cpp,0)+coalesce(r.employer_ei,0),0),
 (je,income_tax_payable,0,coalesce(r.income_tax,0)),
 (je,cpp_payable,0,coalesce(r.cpp,0)),
 (je,cpp2_payable,0,coalesce(r.cpp2,0)),
 (je,ei_payable,0,coalesce(r.ei,0)),
 (je,net_payable,0,coalesce(r.total_net_pay,0));

 update public.dv_accounting_payroll_runs
 set status='POSTED', journal_entry_id=je, posted_at=now(), company_id=company
 where id=r.id;

 total_remit:=coalesce(r.income_tax,0)+coalesce(r.cpp,0)+coalesce(r.cpp2,0)+coalesce(r.ei,0)+coalesce(r.employer_cpp,0)+coalesce(r.employer_ei,0);
 select coalesce((select value->>'frequency' from public.dv_accounting_settings where company_id=company and key='PAYROLL_REMITTER_FREQUENCY'),'MONTHLY') into remitter;
 if remitter='QUARTERLY' then
   due:=(date_trunc('quarter',coalesce(r.pay_date,r.period_end,current_date))::date + interval '3 months' + interval '14 days')::date;
 else
   due:=(date_trunc('month',coalesce(r.pay_date,r.period_end,current_date))::date + interval '1 month' + interval '14 days')::date;
 end if;

 if not exists(select 1 from public.dv_accounting_payroll_remittances where payroll_run_id=r.id) then
   insert into public.dv_accounting_payroll_remittances(company_id,payroll_run_id,remittance_date,period_start,period_end,due_date,income_tax,cpp,ei,employer_cpp,employer_ei,total_remittance,status)
   values(company,r.id,coalesce(r.pay_date,r.period_end,current_date),r.period_start,r.period_end,due,coalesce(r.income_tax,0),coalesce(r.cpp,0)+coalesce(r.cpp2,0),coalesce(r.ei,0),coalesce(r.employer_cpp,0),coalesce(r.employer_ei,0),total_remit,'OPEN');
 end if;

 return jsonb_build_object('ok',true,'journal_entry_id',je,'remittance_amount',total_remit,'due_date',due);
end $$;

revoke all on function public.dv_accounting_post_payroll(uuid) from public;
grant execute on function public.dv_accounting_post_payroll(uuid) to authenticated;
