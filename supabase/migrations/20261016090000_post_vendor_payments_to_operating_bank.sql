-- Post vendor invoice payments to the selected operating bank ledger as well as the GL.
-- Bank balances in the app are calculated from dv_accounting_bank_transactions, so a journal-only
-- posting leaves the operating account balance unchanged.

create or replace function public.dv_accounting_pay_expense_v2(
  p_expense_id uuid,
  p_payment_source text,
  p_bank_account_id uuid default null,
  p_employee_id uuid default null,
  p_payee_name text default null,
  p_payment_amount numeric default null,
  p_payment_date date default current_date,
  p_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
 e public.dv_accounting_expenses%rowtype;
 b public.dv_accounting_bank_accounts%rowtype;
 emp public.dv_accounting_employees%rowtype;
 ap uuid;
 credit_gl uuid;
 je uuid;
 payment_id uuid;
 v_total numeric(14,2);
 v_paid numeric(14,2);
 v_remaining numeric(14,2);
 v_amount numeric(14,2);
 v_status text;
 v_source text;
 v_payee text;
 v_code text;
 v_gl_name text;
 v_payee_type text;
begin
 v_source := upper(trim(coalesce(p_payment_source,'')));
 if v_source not in ('BANK','EMPLOYEE','SHAREHOLDER','OTHER') then raise exception 'Unsupported payment source'; end if;
 select * into e from public.dv_accounting_expenses where id=p_expense_id for update;
 if not found then raise exception 'Vendor invoice not found'; end if;
 if e.posted_at is null then raise exception 'Invoice must be posted before payment'; end if;
 if e.approval_status <> 'APPROVED' then raise exception 'Invoice must be approved before payment'; end if;
 v_total := round(coalesce(e.amount,0)+coalesce(e.hst_amount,0),2);
 select coalesce(sum(amount),0) into v_paid from public.dv_accounting_expense_payments where expense_id=e.id;
 if v_paid=0 and e.payment_status='PAID' then v_paid:=v_total; end if;
 v_remaining:=round(v_total-v_paid,2);
 v_amount:=round(coalesce(p_payment_amount,0),2);
 if v_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if v_amount>v_remaining then raise exception 'Payment exceeds remaining balance of %',v_remaining; end if;
 select id into ap from public.dv_accounting_gl_accounts where company_id=e.company_id and code='2000';
 if ap is null then raise exception 'Accounts Payable account is missing'; end if;

 if v_source='BANK' then
   select * into b from public.dv_accounting_bank_accounts where id=p_bank_account_id and active=true for update;
   if not found then raise exception 'Operating bank account not found'; end if;
   if b.company_id is distinct from e.company_id or b.account_type <> 'OPERATING' then raise exception 'Payment must use an Operating account belonging to the company'; end if;
   insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
   values(e.company_id,'1000','Operating Bank','ASSET') on conflict(company_id,code) do nothing;
   select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1000';
   v_payee_type:='VENDOR'; v_payee:=coalesce(nullif(trim(p_payee_name),''),e.vendor);
 elsif v_source='EMPLOYEE' then
   if p_employee_id is null then raise exception 'Select the employee who paid'; end if;
   select * into emp from public.dv_accounting_employees where id=p_employee_id and company_id=e.company_id and active=true;
   if not found then raise exception 'Active employee not found for this company'; end if;
   v_payee:=emp.name; v_payee_type:='EMPLOYEE'; v_code:='LIB-EMP-REIMB'; v_gl_name:='Employee Reimbursements Payable';
   insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(e.company_id,v_code,v_gl_name,'LIABILITY') on conflict(company_id,code) do nothing;
   select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code=v_code;
 elsif v_source='SHAREHOLDER' then
   v_payee:=nullif(trim(p_payee_name),'');
   if v_payee is null then raise exception 'Enter the director/shareholder name'; end if;
   v_payee_type:='SHAREHOLDER'; v_code:='LIB-SHAREHOLDER-ST'; v_gl_name:='Shareholder / Director Loan - Current';
   insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(e.company_id,v_code,v_gl_name,'LIABILITY') on conflict(company_id,code) do nothing;
   select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code=v_code;
 else
   v_payee:=nullif(trim(p_payee_name),'');
   if v_payee is null then raise exception 'Enter the name of the person who paid'; end if;
   v_payee_type:='OTHER'; v_code:='LIB-OTHER-REIMB'; v_gl_name:='Other Personal Reimbursements Payable';
   insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(e.company_id,v_code,v_gl_name,'LIABILITY') on conflict(company_id,code) do nothing;
   select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code=v_code;
 end if;

 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(e.company_id,coalesce(p_payment_date,current_date),'EXPENSE_PAYMENT',
   e.id,case when v_source='BANK' then 'Vendor invoice payment' else 'Vendor invoice paid personally by '||v_payee end||
   case when nullif(trim(p_reference),'') is not null then ' - '||trim(p_reference) else '' end)
 returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,ap,v_amount,0);
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,credit_gl,0,v_amount);

 insert into public.dv_accounting_expense_payments(
   company_id,expense_id,payment_date,amount,bank_account_id,reference,journal_entry_id,
   paid_by,payment_source,payee_type,payee_name,employee_id
 )
 values(
   e.company_id,e.id,coalesce(p_payment_date,current_date),v_amount,
   case when v_source='BANK' then p_bank_account_id else null end,
   nullif(trim(p_reference),''),je,auth.uid(),v_source,v_payee_type,v_payee,
   case when v_source='EMPLOYEE' then p_employee_id else null end
 ) returning id into payment_id;

 if v_source='BANK' then
   insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
   values(
     p_bank_account_id,coalesce(p_payment_date,current_date),
     'Vendor invoice payment: '||coalesce(e.vendor,'Vendor')||' [expense-payment:'||payment_id::text||']',
     -v_amount,false,nullif(trim(p_reference),'')
   );
 end if;

 v_paid:=round(v_paid+v_amount,2);
 v_status:=case when v_paid>=v_total then 'PAID' else 'PARTIAL' end;
 update public.dv_accounting_expenses
 set payment_status=v_status,paid_at=case when v_status='PAID' then now() else paid_at end,
     bank_account_id=case when v_source='BANK' then p_bank_account_id else null end
 where id=e.id;
 return jsonb_build_object('expense_id',e.id,'journal_entry_id',je,'payment_id',payment_id,
   'payment_amount',v_amount,'paid_total',v_paid,'remaining_balance',greatest(v_total-v_paid,0),
   'status',v_status,'payment_source',v_source,'payee_name',v_payee);
end
$function$;

-- Repair historical bank-funded vendor payments that were journaled but never added to the bank ledger.
insert into public.dv_accounting_bank_transactions(bank_account_id,transaction_date,description,amount,reconciled,reference)
select p.bank_account_id,p.payment_date,
       'Vendor invoice payment: '||coalesce(e.vendor,'Vendor')||' [expense-payment:'||p.id::text||']',
       -p.amount,false,p.reference
from public.dv_accounting_expense_payments p
join public.dv_accounting_expenses e on e.id=p.expense_id
join public.dv_accounting_bank_accounts b on b.id=p.bank_account_id
where upper(coalesce(p.payment_source,'BANK'))='BANK'
  and b.account_type='OPERATING'
  and not exists (
    select 1 from public.dv_accounting_bank_transactions bt
    where bt.description like '%[expense-payment:'||p.id::text||']%'
  );
