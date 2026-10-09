-- DV Real Estate Accounting - complete Supabase installer
-- Run this entire file once in the Supabase SQL Editor.
-- Applies migrations 0001 through 0014 in order.
-- If your database already has some objects, the migrations use IF NOT EXISTS
-- where appropriate; later ALTER/RPC statements intentionally update the schema.


-- ============================================================
-- 0001_accounting_core.sql
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.dv_accounting_companies(
 id uuid primary key default gen_random_uuid(),
 name text not null,
 legal_name text,
 hst_number text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_bank_accounts(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 account_type text not null check(account_type in('REAL_ESTATE_TRUST','COMMISSION_TRUST','OPERATING')),
 institution text,
 account_number_last4 text,
 opening_balance numeric(14,2) not null default 0,
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_gl_accounts(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 code text not null,
 name text not null,
 account_type text not null,
 active boolean not null default true,
 unique(company_id,code)
);

create table if not exists public.dv_accounting_transactions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 transaction_number text,
 status text not null default 'DRAFT',
 transaction_date date,
 property_address text,
 client_name text,
 side text,
 sale_price numeric(14,2) default 0,
 gross_commission numeric(14,2) default 0,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_expenses(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 expense_date date not null,
 vendor text,
 category text,
 description text,
 amount numeric(14,2) not null default 0,
 hst_amount numeric(14,2) not null default 0,
 status text not null default 'OPEN',
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_journal_entries(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 entry_date date not null,
 source_type text,
 source_id uuid,
 memo text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_journal_lines(
 id uuid primary key default gen_random_uuid(),
 journal_entry_id uuid not null references public.dv_accounting_journal_entries(id) on delete cascade,
 gl_account_id uuid not null references public.dv_accounting_gl_accounts(id),
 debit numeric(14,2) not null default 0,
 credit numeric(14,2) not null default 0
);

create table if not exists public.dv_accounting_reconciliations(
 id uuid primary key default gen_random_uuid(),
 bank_account_id uuid not null references public.dv_accounting_bank_accounts(id),
 period_end date not null,
 statement_balance numeric(14,2) not null default 0,
 book_balance numeric(14,2) not null default 0,
 status text not null default 'OPEN',
 reviewed_by uuid,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(bank_account_id,period_end)
);

create table if not exists public.dv_accounting_hst_periods(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 period_start date not null,
 period_end date not null,
 frequency text not null check(frequency in('MONTHLY','QUARTERLY','ANNUAL')),
 hst_collected numeric(14,2) not null default 0,
 itc_claimable numeric(14,2) not null default 0,
 adjustments numeric(14,2) not null default 0,
 net_hst numeric(14,2) generated always as(hst_collected-itc_claimable+adjustments) stored,
 status text not null default 'OPEN',
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_employees(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 email text,
 hourly_rate numeric(12,2) default 0,
 annual_salary numeric(14,2) default 0,
 active boolean not null default true
);

create table if not exists public.dv_accounting_time_entries(
 id uuid primary key default gen_random_uuid(),
 employee_id uuid not null references public.dv_accounting_employees(id),
 work_date date not null,
 clock_in timestamptz,
 clock_out timestamptz,
 hours numeric(8,2) default 0,
 approved boolean not null default false
);

create table if not exists public.dv_accounting_payroll_runs(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 period_start date not null,
 period_end date not null,
 pay_date date,
 gross_pay numeric(14,2) default 0,
 cpp numeric(14,2) default 0,
 cpp2 numeric(14,2) default 0,
 ei numeric(14,2) default 0,
 income_tax numeric(14,2) default 0,
 employer_cpp numeric(14,2) default 0,
 employer_ei numeric(14,2) default 0,
 status text not null default 'DRAFT'
);

create index if not exists idx_dv_accounting_tx_date on public.dv_accounting_transactions(transaction_date);
create index if not exists idx_dv_accounting_expense_date on public.dv_accounting_expenses(expense_date);
create index if not exists idx_dv_accounting_hst_period on public.dv_accounting_hst_periods(period_end);

alter table public.dv_accounting_companies enable row level security;
alter table public.dv_accounting_bank_accounts enable row level security;
alter table public.dv_accounting_gl_accounts enable row level security;
alter table public.dv_accounting_transactions enable row level security;
alter table public.dv_accounting_expenses enable row level security;
alter table public.dv_accounting_journal_entries enable row level security;
alter table public.dv_accounting_journal_lines enable row level security;
alter table public.dv_accounting_reconciliations enable row level security;
alter table public.dv_accounting_hst_periods enable row level security;
alter table public.dv_accounting_employees enable row level security;
alter table public.dv_accounting_time_entries enable row level security;
alter table public.dv_accounting_payroll_runs enable row level security;

-- Development bootstrap: authenticated users can work with accounting records.
-- Tighten these policies to company/role membership before production use.
do $$ declare t text; begin
 for t in select unnest(array[
 'dv_accounting_companies','dv_accounting_bank_accounts','dv_accounting_gl_accounts',
 'dv_accounting_transactions','dv_accounting_expenses','dv_accounting_journal_entries',
 'dv_accounting_journal_lines','dv_accounting_reconciliations','dv_accounting_hst_periods',
 'dv_accounting_employees','dv_accounting_time_entries','dv_accounting_payroll_runs']) loop
   execute format('drop policy if exists "authenticated access" on public.%I',t);
   execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;

-- ============================================================
-- 0002_operations.sql
-- ============================================================

create table if not exists public.dv_accounting_agents(
 id uuid primary key default gen_random_uuid(), company_id uuid references public.dv_accounting_companies(id),
 name text not null, email text, phone text, license_number text, active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.dv_accounting_listings(
 id uuid primary key default gen_random_uuid(), company_id uuid references public.dv_accounting_companies(id),
 listing_number text, address text not null, agent_id uuid references public.dv_accounting_agents(id),
 list_price numeric(14,2) default 0, list_date date, sold_date date, status text not null default 'ACTIVE',
 created_at timestamptz not null default now()
);
create table if not exists public.dv_accounting_commissions(
 id uuid primary key default gen_random_uuid(), transaction_id uuid references public.dv_accounting_transactions(id) on delete cascade,
 agent_id uuid references public.dv_accounting_agents(id), gross_commission numeric(14,2) default 0,
 brokerage_share numeric(14,2) default 0, agent_share numeric(14,2) default 0,
 status text not null default 'UNPAID', paid_date date
);
create table if not exists public.dv_accounting_bank_transactions(
 id uuid primary key default gen_random_uuid(), bank_account_id uuid references public.dv_accounting_bank_accounts(id),
 transaction_date date not null, description text, amount numeric(14,2) not null default 0,
 reconciled boolean not null default false, reference text
);
create table if not exists public.dv_accounting_payroll_lines(
 id uuid primary key default gen_random_uuid(), payroll_run_id uuid references public.dv_accounting_payroll_runs(id) on delete cascade,
 employee_id uuid references public.dv_accounting_employees(id), regular_hours numeric(8,2) default 0,
 overtime_hours numeric(8,2) default 0, gross_pay numeric(14,2) default 0,
 income_tax numeric(14,2) default 0, cpp numeric(14,2) default 0, cpp2 numeric(14,2) default 0,
 ei numeric(14,2) default 0, net_pay numeric(14,2) default 0
);
create table if not exists public.dv_accounting_payroll_remittances(
 id uuid primary key default gen_random_uuid(), company_id uuid references public.dv_accounting_companies(id),
 remittance_date date, period_start date, period_end date, income_tax numeric(14,2) default 0,
 cpp numeric(14,2) default 0, ei numeric(14,2) default 0, employer_cpp numeric(14,2) default 0,
 employer_ei numeric(14,2) default 0, status text not null default 'OPEN', confirmation_number text
);
create table if not exists public.dv_accounting_month_end(
 id uuid primary key default gen_random_uuid(), company_id uuid references public.dv_accounting_companies(id),
 period_end date not null, trust_reconciled boolean default false, commission_trust_reconciled boolean default false,
 operating_reconciled boolean default false, trust_liability_agrees boolean default false,
 hst_reviewed boolean default false, payroll_reviewed boolean default false, pnl_reviewed boolean default false,
 closed_at timestamptz, closed_by uuid, unique(company_id,period_end)
);
create table if not exists public.dv_accounting_settings(
 id uuid primary key default gen_random_uuid(), company_id uuid references public.dv_accounting_companies(id),
 key text not null, value jsonb not null default '{}'::jsonb, unique(company_id,key)
);
create index if not exists idx_dv_accounting_agents_name on public.dv_accounting_agents(name);
create index if not exists idx_dv_accounting_bank_tx_date on public.dv_accounting_bank_transactions(transaction_date);
create index if not exists idx_dv_accounting_commissions_agent on public.dv_accounting_commissions(agent_id);
alter table public.dv_accounting_agents enable row level security;
alter table public.dv_accounting_listings enable row level security;
alter table public.dv_accounting_commissions enable row level security;
alter table public.dv_accounting_bank_transactions enable row level security;
alter table public.dv_accounting_payroll_lines enable row level security;
alter table public.dv_accounting_payroll_remittances enable row level security;
alter table public.dv_accounting_month_end enable row level security;
alter table public.dv_accounting_settings enable row level security;
do $$ declare t text; begin
 for t in select unnest(array['dv_accounting_agents','dv_accounting_listings','dv_accounting_commissions','dv_accounting_bank_transactions','dv_accounting_payroll_lines','dv_accounting_payroll_remittances','dv_accounting_month_end','dv_accounting_settings']) loop
   execute format('drop policy if exists "authenticated access" on public.%I',t);
   execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;

-- ============================================================
-- 0003_accounting_engine.sql
-- ============================================================

alter table public.dv_accounting_transactions
 add column if not exists hst_amount numeric(14,2) not null default 0,
 add column if not exists agent_commission numeric(14,2) not null default 0,
 add column if not exists outside_broker_amount numeric(14,2) not null default 0,
 add column if not exists deposit_amount numeric(14,2) not null default 0,
 add column if not exists trust_account_type text default 'REAL_ESTATE_TRUST',
 add column if not exists finalized_at timestamptz;

create or replace function public.dv_accounting_finalize_transaction(p_transaction_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 t public.dv_accounting_transactions%rowtype;
 company uuid;
 je uuid;
 ar uuid; rev uuid; hst uuid; agent_exp uuid; agent_pay uuid;
 agent_amt numeric(14,2);
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
 values(je,ar,coalesce(t.gross_commission,0)+coalesce(t.hst_amount,0),0),
       (je,rev,0,coalesce(t.gross_commission,0));
 if coalesce(t.hst_amount,0)<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,hst,0,t.hst_amount);
 end if;
 if agent_amt<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,agent_exp,agent_amt,0),(je,agent_pay,0,agent_amt);
 end if;

 update public.dv_accounting_transactions
 set status='FINALIZED', finalized_at=now(), company_id=company
 where id=t.id;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'agent_commission',agent_amt);
end $$;

revoke all on function public.dv_accounting_finalize_transaction(uuid) from public;
grant execute on function public.dv_accounting_finalize_transaction(uuid) to authenticated;

-- ============================================================
-- 0004_staff_vendors_categories.sql
-- ============================================================

-- Staff pay setup, time tracking, vendors and configurable accounting categories
alter table public.dv_accounting_employees
  add column if not exists pay_type text not null default 'HOURLY'
    check (pay_type in ('HOURLY','SALARY')),
  add column if not exists pay_frequency text not null default 'BIWEEKLY'
    check (pay_frequency in ('WEEKLY','BIWEEKLY','SEMI_MONTHLY','MONTHLY')),
  add column if not exists overtime_rate_multiplier numeric(6,3) not null default 1.5,
  add column if not exists vacation_pay_rate numeric(6,4) not null default 0.04,
  add column if not exists hire_date date,
  add column if not exists department text,
  add column if not exists job_title text;

alter table public.dv_accounting_time_entries
  add column if not exists overtime_hours numeric(8,2) not null default 0,
  add column if not exists notes text;

create table if not exists public.dv_accounting_vendors(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 contact_name text,
 email text,
 phone text,
 address text,
 hst_number text,
 default_expense_category_id uuid,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name)
);

create table if not exists public.dv_accounting_expense_categories(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 code text,
 description text,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name)
);

create table if not exists public.dv_accounting_income_categories(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 code text,
 description text,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name)
);

create index if not exists idx_dv_accounting_vendors_name on public.dv_accounting_vendors(name);
create index if not exists idx_dv_accounting_expense_categories_name on public.dv_accounting_expense_categories(name);
create index if not exists idx_dv_accounting_income_categories_name on public.dv_accounting_income_categories(name);

alter table public.dv_accounting_vendors enable row level security;
alter table public.dv_accounting_expense_categories enable row level security;
alter table public.dv_accounting_income_categories enable row level security;

do $$ declare t text; begin
 for t in select unnest(array[
   'dv_accounting_vendors',
   'dv_accounting_expense_categories',
   'dv_accounting_income_categories'
 ]) loop
   execute format('drop policy if exists "authenticated access" on public.%I',t);
   execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;


-- ============================================================
-- 0005_cra_payroll.sql
-- ============================================================

-- CRA payroll setup and statutory deduction fields
alter table public.dv_accounting_employees
  add column if not exists province text not null default 'ON',
  add column if not exists date_of_birth date,
  add column if not exists federal_claim_code integer not null default 1,
  add column if not exists ontario_claim_code integer not null default 1,
  add column if not exists additional_tax numeric(12,2) not null default 0,
  add column if not exists cpp_exempt boolean not null default false,
  add column if not exists ei_exempt boolean not null default false;

alter table public.dv_accounting_payroll_lines
  add column if not exists employer_cpp numeric(14,2) not null default 0,
  add column if not exists employer_ei numeric(14,2) not null default 0,
  add column if not exists annual_taxable_income numeric(14,2) not null default 0;

alter table public.dv_accounting_payroll_runs
  add column if not exists tax_year integer not null default extract(year from current_date)::integer,
  add column if not exists employer_cpp numeric(14,2) not null default 0,
  add column if not exists employer_ei numeric(14,2) not null default 0,
  add column if not exists total_deductions numeric(14,2) not null default 0,
  add column if not exists total_net_pay numeric(14,2) not null default 0,
  add column if not exists calculated_at timestamptz;

create index if not exists idx_dv_accounting_payroll_lines_employee on public.dv_accounting_payroll_lines(employee_id);
create index if not exists idx_dv_accounting_payroll_runs_year on public.dv_accounting_payroll_runs(tax_year);

-- CRA remittance frequency is configured at company level.
insert into public.dv_accounting_settings(company_id,key,value)
select c.id,'PAYROLL_REMITTER_FREQUENCY','{"frequency":"MONTHLY"}'::jsonb
from public.dv_accounting_companies c
where not exists(
  select 1 from public.dv_accounting_settings s
  where s.company_id=c.id and s.key='PAYROLL_REMITTER_FREQUENCY'
);


-- ============================================================
-- 0006_payroll_posting.sql
-- ============================================================

-- Payroll posting, approval and CRA remittance tracking
alter table public.dv_accounting_payroll_runs
  add column if not exists journal_entry_id uuid references public.dv_accounting_journal_entries(id),
  add column if not exists approved_at timestamptz,
  add column if not exists posted_at timestamptz;

alter table public.dv_accounting_payroll_remittances
  add column if not exists payroll_run_id uuid references public.dv_accounting_payroll_runs(id),
  add column if not exists due_date date,
  add column if not exists total_remittance numeric(14,2) not null default 0,
  add column if not exists paid_at timestamptz;

create unique index if not exists uq_dv_payroll_remittance_run
  on public.dv_accounting_payroll_remittances(payroll_run_id)
  where payroll_run_id is not null;

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

 insert into public.dv_accounting_payroll_remittances(company_id,payroll_run_id,remittance_date,period_start,period_end,due_date,income_tax,cpp,ei,employer_cpp,employer_ei,total_remittance,status)
 values(company,r.id,coalesce(r.pay_date,r.period_end,current_date),r.period_start,r.period_end,due,coalesce(r.income_tax,0),coalesce(r.cpp,0)+coalesce(r.cpp2,0),coalesce(r.ei,0),coalesce(r.employer_cpp,0),coalesce(r.employer_ei,0),total_remit,'OPEN')
 on conflict(payroll_run_id) do nothing;

 return jsonb_build_object('ok',true,'journal_entry_id',je,'remittance_amount',total_remit,'due_date',due);
end $$;

revoke all on function public.dv_accounting_post_payroll(uuid) from public;
grant execute on function public.dv_accounting_post_payroll(uuid) to authenticated;


-- ============================================================
-- 0007_fix_payroll_posting.sql
-- ============================================================

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


-- ============================================================
-- 0008_employer_cpp2.sql
-- ============================================================

-- Track employer CPP2 separately
alter table public.dv_accounting_payroll_runs
  add column if not exists employer_cpp2 numeric(14,2) not null default 0;

alter table public.dv_accounting_payroll_remittances
  add column if not exists employer_cpp2 numeric(14,2) not null default 0;

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
 (je,employer_tax,coalesce(r.employer_cpp,0)+coalesce(r.employer_cpp2,0)+coalesce(r.employer_ei,0),0),
 (je,income_tax_payable,0,coalesce(r.income_tax,0)),
 (je,cpp_payable,0,coalesce(r.cpp,0)),
 (je,cpp2_payable,0,coalesce(r.cpp2,0)),
 (je,ei_payable,0,coalesce(r.ei,0)),
 (je,net_payable,0,coalesce(r.total_net_pay,0));

 update public.dv_accounting_payroll_runs
 set status='POSTED',journal_entry_id=je,posted_at=now(),company_id=company
 where id=r.id;

 total_remit:=coalesce(r.income_tax,0)+coalesce(r.cpp,0)+coalesce(r.cpp2,0)+coalesce(r.ei,0)+coalesce(r.employer_cpp,0)+coalesce(r.employer_cpp2,0)+coalesce(r.employer_ei,0);
 select coalesce((select value->>'frequency' from public.dv_accounting_settings where company_id=company and key='PAYROLL_REMITTER_FREQUENCY'),'MONTHLY') into remitter;
 if remitter='QUARTERLY' then
   due:=(date_trunc('quarter',coalesce(r.pay_date,r.period_end,current_date))::date+interval '3 months'+interval '14 days')::date;
 else
   due:=(date_trunc('month',coalesce(r.pay_date,r.period_end,current_date))::date+interval '1 month'+interval '14 days')::date;
 end if;

 if not exists(select 1 from public.dv_accounting_payroll_remittances where payroll_run_id=r.id) then
   insert into public.dv_accounting_payroll_remittances(company_id,payroll_run_id,remittance_date,period_start,period_end,due_date,income_tax,cpp,employer_cpp2,ei,employer_cpp,employer_ei,total_remittance,status)
   values(company,r.id,coalesce(r.pay_date,r.period_end,current_date),r.period_start,r.period_end,due,coalesce(r.income_tax,0),coalesce(r.cpp,0)+coalesce(r.cpp2,0),coalesce(r.employer_cpp2,0),coalesce(r.ei,0),coalesce(r.employer_cpp,0),coalesce(r.employer_ei,0),total_remit,'OPEN');
 end if;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'remittance_amount',total_remit,'due_date',due);
end $$;

revoke all on function public.dv_accounting_post_payroll(uuid) from public;
grant execute on function public.dv_accounting_post_payroll(uuid) to authenticated;


-- ============================================================
-- 0009_hst_workflow.sql
-- ============================================================

create table if not exists public.dv_accounting_hst_adjustments(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 hst_period_id uuid references public.dv_accounting_hst_periods(id) on delete cascade,
 adjustment_date date not null default current_date,
 amount numeric(14,2) not null default 0,
 reason text not null,
 created_at timestamptz not null default now()
);
alter table public.dv_accounting_hst_periods add column if not exists filing_due_date date;
alter table public.dv_accounting_hst_periods add column if not exists filed_at timestamptz;
alter table public.dv_accounting_hst_periods add column if not exists paid_at timestamptz;
alter table public.dv_accounting_hst_periods add column if not exists payment_amount numeric(14,2);
alter table public.dv_accounting_hst_periods add column if not exists confirmation_number text;
alter table public.dv_accounting_hst_periods add column if not exists reviewed_at timestamptz;
alter table public.dv_accounting_hst_adjustments enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_hst_adjustments;
create policy "authenticated access" on public.dv_accounting_hst_adjustments for all to authenticated using(true) with check(true);


-- ============================================================
-- 0010_trust_accounting.sql
-- ============================================================

-- Trust accounting and monthly reconciliation
create table if not exists public.dv_accounting_trust_transactions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 bank_account_id uuid references public.dv_accounting_bank_accounts(id),
 transaction_id uuid references public.dv_accounting_transactions(id),
 ledger_date date not null default current_date,
 trust_account_type text not null check (trust_account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
 direction text not null check (direction in ('DEPOSIT','DISBURSEMENT')),
 client_name text,
 matter text,
 description text not null,
 amount numeric(14,2) not null check (amount>0),
 reference text,
 status text not null default 'POSTED' check (status in ('POSTED','VOID')),
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_trust_liabilities(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 trust_transaction_id uuid references public.dv_accounting_trust_transactions(id) on delete cascade,
 transaction_id uuid references public.dv_accounting_transactions(id),
 trust_account_type text not null check (trust_account_type in ('REAL_ESTATE_TRUST','COMMISSION_TRUST')),
 client_name text,
 matter text,
 amount numeric(14,2) not null check (amount>0),
 direction text not null check (direction in ('RECEIVABLE','RELEASED')),
 created_at timestamptz not null default now()
);

alter table public.dv_accounting_reconciliations add column if not exists trust_liability_balance numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists bank_to_book_difference numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists bank_to_liability_difference numeric(14,2) not null default 0;
alter table public.dv_accounting_reconciliations add column if not exists reviewed_by text;
alter table public.dv_accounting_reconciliations add column if not exists review_signed_at timestamptz;

alter table public.dv_accounting_trust_transactions enable row level security;
alter table public.dv_accounting_trust_liabilities enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_trust_transactions;
drop policy if exists "authenticated access" on public.dv_accounting_trust_liabilities;
create policy "authenticated access" on public.dv_accounting_trust_transactions for all to authenticated using(true) with check(true);
create policy "authenticated access" on public.dv_accounting_trust_liabilities for all to authenticated using(true) with check(true);

create or replace function public.dv_accounting_post_trust_transaction(
 p_company_id uuid,
 p_bank_account_id uuid,
 p_transaction_id uuid,
 p_ledger_date date,
 p_trust_account_type text,
 p_direction text,
 p_client_name text,
 p_matter text,
 p_description text,
 p_amount numeric,
 p_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare tt uuid; li uuid; company uuid; bank_type text;
begin
 if p_amount is null or p_amount<=0 then raise exception 'Trust amount must be greater than zero'; end if;
 if p_direction not in ('DEPOSIT','DISBURSEMENT') then raise exception 'Invalid trust direction'; end if;
 select account_type into bank_type from public.dv_accounting_bank_accounts where id=p_bank_account_id;
 if bank_type is null then raise exception 'Trust bank account not found'; end if;
 if bank_type<>p_trust_account_type then raise exception 'Bank account type does not match trust account type'; end if;
 company:=coalesce(p_company_id,(select company_id from public.dv_accounting_bank_accounts where id=p_bank_account_id));
 insert into public.dv_accounting_trust_transactions(company_id,bank_account_id,transaction_id,ledger_date,trust_account_type,direction,client_name,matter,description,amount,reference)
 values(company,p_bank_account_id,p_transaction_id,coalesce(p_ledger_date,current_date),p_trust_account_type,p_direction,p_client_name,p_matter,p_description,p_amount,p_reference)
 returning id into tt;
 insert into public.dv_accounting_trust_liabilities(company_id,trust_transaction_id,transaction_id,trust_account_type,client_name,matter,amount,direction)
 values(company,tt,p_transaction_id,p_trust_account_type,p_client_name,p_matter,p_amount,case when p_direction='DEPOSIT' then 'RECEIVABLE' else 'RELEASED' end)
 returning id into li;
 return jsonb_build_object('ok',true,'trust_transaction_id',tt,'liability_id',li);
end $$;

revoke all on function public.dv_accounting_post_trust_transaction(uuid,uuid,uuid,date,text,text,text,text,text,numeric,text) from public;
grant execute on function public.dv_accounting_post_trust_transaction(uuid,uuid,uuid,date,text,text,text,text,text,numeric,text) to authenticated;


-- ============================================================
-- 0011_trust_posting_complete.sql
-- ============================================================

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


-- ============================================================
-- 0012_transaction_trust_integration.sql
-- ============================================================

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


-- ============================================================
-- 0013_operating_expense_accounting.sql
-- ============================================================

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


-- ============================================================
-- 0014_unified_categories.sql
-- ============================================================

-- Unified income/expense category master
create table if not exists public.dv_accounting_categories(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.dv_accounting_companies(id),
 name text not null,
 code text,
 category_type text not null check(category_type in ('INCOME','EXPENSE')),
 description text,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name,category_type)
);
alter table public.dv_accounting_categories enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_categories;
create policy "authenticated access" on public.dv_accounting_categories for all to authenticated using(true) with check(true);
insert into public.dv_accounting_categories(company_id,name,code,category_type,description,active)
select company_id,name,code,'EXPENSE',description,active from public.dv_accounting_expense_categories
on conflict(company_id,name,category_type) do nothing;
insert into public.dv_accounting_categories(company_id,name,code,category_type,description,active)
select company_id,name,code,'INCOME',description,active from public.dv_accounting_income_categories
on conflict(company_id,name,category_type) do nothing;
create index if not exists idx_dv_accounting_categories_type on public.dv_accounting_categories(company_id,category_type,active);

