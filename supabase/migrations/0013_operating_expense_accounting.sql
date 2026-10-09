-- Operating account and expense accounting engine
alter table public.dv_accounting_expenses
  add column if not exists journal_entry_id uuid references public.dv_accounting_journal_entries(id),
  add column if not exists posted_at timestamptz,
  add column if not exists payment_status text not null default 'UNPAID' check(payment_status in ('UNPAID','PAID')),
  add column if not exists paid_at timestamptz,
  add column if not exists bank_account_id uuid references public.dv_accounting_bank_accounts(id),
  add column if not exists total_amount numeric(14,2) generated always as(amount+hst_amount) stored;

alter table public.dv_accounting_expenses
  drop constraint if exists dv_accounting_expenses_bank_account_check;

create index if not exists idx_dv_accounting_expense_status on public.dv_accounting_expenses(status,payment_status);
create index if not exists idx_dv_accounting_expense_bank on public.dv_accounting_expenses(bank_account_id);

-- Post an expense. Amount is before HST; total cash/AP is amount + HST.
create or replace function public.dv_accounting_post_expense(p_expense_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.dv_accounting_expenses%rowtype;
  je uuid;
  expense_gl uuid;
  itc_gl uuid;
  credit_gl uuid;
  bank public.dv_accounting_bank_accounts%rowtype;
  code text;
  total numeric(14,2);
begin
  select * into e from public.dv_accounting_expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if e.posted_at is not null then
    return jsonb_build_object('expense_id',e.id,'journal_entry_id',e.journal_entry_id,'status','ALREADY_POSTED');
  end if;
  if e.amount < 0 or e.hst_amount < 0 then raise exception 'Expense amounts cannot be negative'; end if;
  if e.company_id is null then raise exception 'Expense must belong to a company'; end if;

  total := coalesce(e.amount,0)+coalesce(e.hst_amount,0);

  if e.payment_status='PAID' then
    if e.bank_account_id is null then raise exception 'Select an operating bank account for a paid expense'; end if;
    select * into bank from public.dv_accounting_bank_accounts where id=e.bank_account_id and active=true for update;
    if not found then raise exception 'Operating bank account not found'; end if;
    if bank.company_id is distinct from e.company_id then raise exception 'Bank account does not belong to the expense company'; end if;
    if bank.account_type <> 'OPERATING' then raise exception 'Expense payments must use an Operating account, not a trust account'; end if;
  end if;

  code := '6' || lpad((abs(hashtext(coalesce(nullif(trim(e.category),''),'General Expense'))) % 999)::text,3,'0');
  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
  values(e.company_id,code,coalesce(nullif(trim(e.category),''),'General Expense'),'EXPENSE')
  on conflict(company_id,code) do update set name=excluded.name
  returning id into expense_gl;

  insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
  values(e.company_id,'1300','HST Input Tax Credits','ASSET')
  on conflict(company_id,code) do nothing;
  select id into itc_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1300';

  if e.payment_status='PAID' then
    select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1000';
    if credit_gl is null then
      insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
      values(e.company_id,'1000',bank.name,'ASSET')
      on conflict(company_id,code) do nothing;
      select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1000';
    end if;
  else
    insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
    values(e.company_id,'2000','Accounts Payable','LIABILITY')
    on conflict(company_id,code) do nothing;
    select id into credit_gl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='2000';
  end if;

  insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
  values(e.company_id,e.expense_date,'EXPENSE',e.id,coalesce(e.description,'Expense'))
  returning id into je;

  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(je,expense_gl,coalesce(e.amount,0),0);
  if coalesce(e.hst_amount,0) > 0 then
    insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    values(je,itc_gl,e.hst_amount,0);
  end if;
  insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
  values(je,credit_gl,0,total);

  update public.dv_accounting_expenses
    set status='POSTED', journal_entry_id=je, posted_at=now(), paid_at=case when payment_status='PAID' then coalesce(paid_at,now()) else null end
  where id=e.id;

  return jsonb_build_object('expense_id',e.id,'journal_entry_id',je,'status','POSTED');
end $$;

create or replace function public.dv_accounting_pay_expense(p_expense_id uuid,p_bank_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 e public.dv_accounting_expenses%rowtype;
 b public.dv_accounting_bank_accounts%rowtype;
 ap uuid;
 bankgl uuid;
 je uuid;
 total numeric(14,2);
begin
 select * into e from public.dv_accounting_expenses where id=p_expense_id for update;
 if not found then raise exception 'Expense not found'; end if;
 if e.posted_at is null then raise exception 'Expense must be posted before payment'; end if;
 if e.payment_status='PAID' then return jsonb_build_object('expense_id',e.id,'status','ALREADY_PAID'); end if;
 select * into b from public.dv_accounting_bank_accounts where id=p_bank_account_id and active=true for update;
 if not found then raise exception 'Operating bank account not found'; end if;
 if b.company_id is distinct from e.company_id or b.account_type <> 'OPERATING' then raise exception 'Payment must use an Operating account belonging to the company'; end if;
 total:=coalesce(e.amount,0)+coalesce(e.hst_amount,0);
 select id into ap from public.dv_accounting_gl_accounts where company_id=e.company_id and code='2000';
 if ap is null then raise exception 'Accounts Payable account is missing'; end if;
 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values(e.company_id,'1000','Operating Bank','ASSET')
 on conflict(company_id,code) do nothing;
 select id into bankgl from public.dv_accounting_gl_accounts where company_id=e.company_id and code='1000';
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(e.company_id,current_date,'EXPENSE_PAYMENT',e.id,'Payment of expense')
 returning id into je;
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,ap,total,0);
 insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit) values(je,bankgl,0,total);
 update public.dv_accounting_expenses set payment_status='PAID',paid_at=now(),bank_account_id=p_bank_account_id where id=e.id;
 return jsonb_build_object('expense_id',e.id,'journal_entry_id',je,'status','PAID');
end $$;

grant execute on function public.dv_accounting_post_expense(uuid) to authenticated;
grant execute on function public.dv_accounting_pay_expense(uuid,uuid) to authenticated;
