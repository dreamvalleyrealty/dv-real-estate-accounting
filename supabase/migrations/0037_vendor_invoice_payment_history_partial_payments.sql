-- 0037: Vendor invoice payment history and partial payments.
create table if not exists public.dv_accounting_expense_payments (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id),
 expense_id uuid not null references public.dv_accounting_expenses(id),
 payment_date date not null default current_date,
 amount numeric(14,2) not null check(amount>0),
 bank_account_id uuid not null references public.dv_accounting_bank_accounts(id),
 reference text,
 journal_entry_id uuid references public.dv_accounting_journal_entries(id),
 paid_by uuid,
 created_at timestamptz not null default now()
);
create index if not exists dv_accounting_expense_payments_expense_idx on public.dv_accounting_expense_payments(expense_id,payment_date,created_at);
alter table public.dv_accounting_expense_payments enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_expense_payments;
create policy "authenticated access" on public.dv_accounting_expense_payments for all to authenticated using(true) with check(true);

alter table public.dv_accounting_expenses add column if not exists approved_at timestamptz;
alter table public.dv_accounting_expenses add column if not exists approved_by uuid;
alter table public.dv_accounting_expenses add column if not exists approval_status text not null default 'APPROVED';
alter table public.dv_accounting_expenses drop constraint if exists dv_accounting_expenses_approval_status_check;
alter table public.dv_accounting_expenses add constraint dv_accounting_expenses_approval_status_check check(approval_status in ('PENDING','APPROVED','REJECTED'));
update public.dv_accounting_expenses set approval_status='APPROVED',approved_at=coalesce(approved_at,posted_at,created_at) where approval_status='PENDING';

drop function if exists public.dv_accounting_pay_expense(uuid,uuid);
create or replace function public.dv_accounting_pay_expense(
 p_expense_id uuid,p_bank_account_id uuid,p_payment_amount numeric,
 p_payment_date date default current_date,p_reference text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare e public.dv_accounting_expenses%rowtype; b public.dv_accounting_bank_accounts%rowtype;
 ap uuid; bankgl uuid; je uuid; v_total numeric(14,2); v_paid numeric(14,2);
 v_remaining numeric(14,2); v_amount numeric(14,2); v_status text;
begin
 select * into e from public.dv_accounting_expenses where id=p_expense_id for update;
 if not found then raise exception 'Vendor invoice not found'; end if;
 if e.posted_at is null then raise exception 'Invoice must be posted before payment'; end if;
 if e.approval_status <> 'APPROVED' then raise exception 'Invoice must be approved before payment'; end if;
 select * into b from public.dv_accounting_bank_accounts where id=p_bank_account_id and active=true for update;
 if not found then raise exception 'Operating bank account not found'; end if;
 if b.company_id is distinct from e.company_id or b.account_type <> 'OPERATING' then raise exception 'Payment must use an Operating account belonging to the company'; end if;
 v_total:=round(coalesce(e.amount,0)+coalesce(e.hst_amount,0),2);
 select coalesce(sum(amount),0) into v_paid from public.dv_accounting_expense_payments where expense_id=e.id;
 if v_paid=0 and e.payment_status='PAID' then v_paid:=v_total; end if;
 v_remaining:=round(v_total-v_paid,2); v_amount:=round(coalesce(p_payment_amount,0),2);
 if v_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if v_amount>v_remaining then raise exception 'Payment exceeds remaining balance of %',v_remaining; end if;
 select id into ap from public.dv_accounting_gl_accounts where company_id=e.company_id and code='2000';
 if ap is null then raise exception 'Accounts Payable account is missing'; end if;
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type) values(e.company_id,'1000','Operating Bank','ASSET') on conflict(company_id,code) do nothing;
 select id into bankgl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1000';
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(e.company_id,coalesce(p_payment_date,current_date),'EXPENSE_PAYMENT',e.id,'Vendor invoice payment'||case when nullif(trim(p_reference),'') is not null then ' - '||trim(p_reference) else '' end) returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,ap,v_amount,0);
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,bankgl,0,v_amount);
 insert into public.dv_accounting_expense_payments(company_id,expense_id,payment_date,amount,bank_account_id,reference,journal_entry_id,paid_by)
 values(e.company_id,e.id,coalesce(p_payment_date,current_date),v_amount,p_bank_account_id,nullif(trim(p_reference),''),je,auth.uid());
 v_paid:=round(v_paid+v_amount,2); v_status:=case when v_paid>=v_total then 'PAID' else 'PARTIAL' end;
 update public.dv_accounting_expenses set payment_status=v_status,paid_at=case when v_status='PAID' then now() else paid_at end,bank_account_id=p_bank_account_id where id=e.id;
 return jsonb_build_object('expense_id',e.id,'journal_entry_id',je,'payment_amount',v_amount,'paid_total',v_paid,'remaining_balance',greatest(v_total-v_paid,0),'status',v_status);
end $$;
grant execute on function public.dv_accounting_pay_expense(uuid,uuid,numeric,date,text) to authenticated;
