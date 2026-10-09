-- DV Real Estate Accounting - complete Supabase installer
-- Run this entire file once in the Supabase SQL Editor.
-- Applies migrations 0001 through 0025 in order.
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



-- ============================================================
-- 0015_branches.sql
-- ============================================================

-- Branches and branch assignments for brokerage structure
create table if not exists public.dv_accounting_branches(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
 name text not null,
 branch_code text,
 address text,
 phone text,
 manager_name text,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name),
 unique(company_id,branch_code)
);

alter table public.dv_accounting_bank_accounts add column if not exists branch_id uuid references public.dv_accounting_branches(id);
alter table public.dv_accounting_agents add column if not exists branch_id uuid references public.dv_accounting_branches(id);
alter table public.dv_accounting_listings add column if not exists branch_id uuid references public.dv_accounting_branches(id);
alter table public.dv_accounting_employees add column if not exists branch_id uuid references public.dv_accounting_branches(id);

create index if not exists idx_dv_accounting_branches_company on public.dv_accounting_branches(company_id);
create index if not exists idx_dv_accounting_agents_branch on public.dv_accounting_agents(branch_id);
create index if not exists idx_dv_accounting_employees_branch on public.dv_accounting_employees(branch_id);
create index if not exists idx_dv_accounting_listings_branch on public.dv_accounting_listings(branch_id);

alter table public.dv_accounting_branches enable row level security;
drop policy if exists "authenticated access" on public.dv_accounting_branches;
create policy "authenticated access" on public.dv_accounting_branches for all to authenticated using(true) with check(true);

-- Ensure existing authenticated users can continue working with the new branch columns.



-- ============================================================
-- 0016_agent_profiles_fees.sql
-- ============================================================

-- Agent master profile, memberships, bank details, fee plans and per-agent overrides

create table if not exists public.dv_accounting_real_estate_boards(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 province text not null default 'ON',
 active boolean not null default true,
 created_at timestamptz not null default now()
);

insert into public.dv_accounting_real_estate_boards(name,province) values
('Toronto Regional Real Estate Board','ON'),
('Mississauga Real Estate Board','ON'),
('Brampton Real Estate Board','ON'),
('Barrie & District Association of REALTORS®','ON'),
('Brantford Regional Real Estate Association','ON'),
('Central Lakes Association of REALTORS®','ON'),
('Chatham-Kent Association of REALTORS®','ON'),
('Cornerstone Association of REALTORS®','ON'),
('Cornwall and District Real Estate Board','ON'),
('Guelph & District Association of REALTORS®','ON'),
('Huron Perth Association of REALTORS®','ON'),
('Kawartha Lakes Real Estate Association','ON'),
('Kingston & Area Real Estate Association','ON'),
('Kitchener-Waterloo Association of REALTORS®','ON'),
('Lakelands Association of REALTORS®','ON'),
('London and St. Thomas Association of REALTORS®','ON'),
('Niagara Association of REALTORS®','ON'),
('North Bay Real Estate Board','ON'),
('Oakville, Milton & District Real Estate Board','ON'),
('OnePoint Association of REALTORS®','ON'),
('Ottawa Real Estate Board','ON'),
('Peterborough & the Kawarthas Association of REALTORS® Inc.','ON'),
('REALTORS® Association of Grey Bruce Owen Sound','ON'),
('REALTORS® Association of Hamilton-Burlington','ON'),
('Renfrew County Real Estate Board','ON'),
('Rideau–St. Lawrence Real Estate Board','ON'),
('Sarnia-Lambton Real Estate Board','ON'),
('Sault Ste. Marie Real Estate Board','ON'),
('Simcoe & District Real Estate Board','ON'),
('Sudbury Real Estate Board','ON'),
('Thunder Bay Real Estate Board','ON'),
('Timmins, Cochrane & Timiskaming Districts Association of REALTORS®','ON'),
('Windsor-Essex County Real Estate Board','ON'),
('Woodstock-Ingersoll & District Real Estate Board','ON'),
('Other / Custom','ON')
on conflict(name) do nothing;

alter table public.dv_accounting_agents
 add column if not exists agent_number text,
 add column if not exists first_name text,
 add column if not exists last_name text,
 add column if not exists legal_name text,
 add column if not exists incorporated boolean not null default false,
 add column if not exists corporation_name text,
 add column if not exists spouse_name text,
 add column if not exists address text,
 add column if not exists city text,
 add column if not exists province text default 'ON',
 add column if not exists postal_code text,
 add column if not exists cell_phone text,
 add column if not exists date_of_birth date,
 add column if not exists start_date date,
 add column if not exists anniversary_date date,
 add column if not exists termination_date date,
 add column if not exists incorporation_date date,
 add column if not exists reco_license_number text,
 add column if not exists reco_license_expiry date,
 add column if not exists hst_number text,
 add column if not exists prec_hst_number text;

create sequence if not exists public.dv_accounting_agent_number_seq start 1;

create or replace function public.dv_accounting_next_agent_number()
returns text language plpgsql as $$
declare n bigint;
begin
 n:=nextval('public.dv_accounting_agent_number_seq');
 return 'A-'||lpad(n::text,5,'0');
end $$;

alter table public.dv_accounting_agents alter column agent_number set default public.dv_accounting_next_agent_number();

update public.dv_accounting_agents
set agent_number=public.dv_accounting_next_agent_number()
where agent_number is null or agent_number='';

create unique index if not exists idx_dv_accounting_agents_agent_number on public.dv_accounting_agents(agent_number);

create table if not exists public.dv_accounting_agent_memberships(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 board_id uuid references public.dv_accounting_real_estate_boards(id),
 board_name text,
 membership_number text not null,
 created_at timestamptz not null default now()
);
create index if not exists idx_dv_accounting_agent_memberships_agent on public.dv_accounting_agent_memberships(agent_id);

create table if not exists public.dv_accounting_fee_plans(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
 name text not null,
 desk_fee numeric(14,2) not null default 0,
 admin_fee numeric(14,2) not null default 0,
 lead_fee numeric(14,2) not null default 0,
 commission_split_percent numeric(7,4) not null default 90,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(company_id,name)
);

create table if not exists public.dv_accounting_agent_fee_settings(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 fee_plan_id uuid references public.dv_accounting_fee_plans(id),
 desk_fee_override numeric(14,2),
 admin_fee_override numeric(14,2),
 lead_fee_override numeric(14,2),
 commission_split_override_percent numeric(7,4),
 notes text,
 effective_date date,
 created_at timestamptz not null default now(),
 unique(agent_id)
);

create table if not exists public.dv_accounting_agent_bank_details(
 id uuid primary key default gen_random_uuid(),
 agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
 bank_name text,
 institution_number text,
 transit_number text,
 account_number text,
 account_type text check(account_type in ('CHEQUING','SAVINGS')),
 account_name text,
 created_at timestamptz not null default now(),
 unique(agent_id)
);

alter table public.dv_accounting_commissions
 add column if not exists commission_split_override_percent numeric(7,4),
 add column if not exists fee_adjustment numeric(14,2) not null default 0,
 add column if not exists adjustment_reason text;

do $$ declare t text; begin
 for t in select unnest(array[
 'dv_accounting_real_estate_boards','dv_accounting_agent_memberships','dv_accounting_fee_plans',
 'dv_accounting_agent_fee_settings','dv_accounting_agent_bank_details'
 ]) loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists "authenticated access" on public.%I',t);
  execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;



-- Migration 0017: Dynamic lead fees by transaction type
alter table public.dv_accounting_fee_plans
  add column if not exists lead_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists lead_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists lead_fee_lease_type text not null default 'AMOUNT',
  add column if not exists lead_fee_lease_value numeric(14,4) not null default 0;

alter table public.dv_accounting_fee_plans
  drop constraint if exists dv_accounting_fee_plans_lead_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_lead_fee_lease_type_check;

alter table public.dv_accounting_fee_plans
  add constraint dv_accounting_fee_plans_lead_fee_buy_sell_type_check check (lead_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_lead_fee_lease_type_check check (lead_fee_lease_type in ('AMOUNT','PERCENT'));

alter table public.dv_accounting_agent_fee_settings
  add column if not exists lead_fee_buy_sell_type text,
  add column if not exists lead_fee_buy_sell_value numeric(14,4),
  add column if not exists lead_fee_lease_type text,
  add column if not exists lead_fee_lease_value numeric(14,4);

alter table public.dv_accounting_agent_fee_settings
  drop constraint if exists dv_accounting_agent_fee_settings_lead_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_settings_lead_fee_lease_type_check;

alter table public.dv_accounting_agent_fee_settings
  add constraint dv_accounting_agent_fee_settings_lead_fee_buy_sell_type_check check (lead_fee_buy_sell_type is null or lead_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_settings_lead_fee_lease_type_check check (lead_fee_lease_type is null or lead_fee_lease_type in ('AMOUNT','PERCENT'));


-- ============================================================
-- 0018_fee_rules_commission_cheques_recurring.sql
-- ============================================================

-- 0018: fee rules, effective-date promotions, commission charges/cheques and recurring fees

alter table public.dv_accounting_transactions
  add column if not exists market_segment text not null default 'RESIDENTIAL'
    check (market_segment in ('RESIDENTIAL','COMMERCIAL'));

alter table public.dv_accounting_fee_plans
  add column if not exists admin_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_lease_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_lease_value numeric(14,4) not null default 0;

alter table public.dv_accounting_agent_fee_settings
  add column if not exists admin_fee_buy_sell_type text,
  add column if not exists admin_fee_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_lease_type text,
  add column if not exists admin_fee_lease_value numeric(14,4),
  add column if not exists admin_fee_commercial_buy_sell_type text,
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_commercial_lease_type text,
  add column if not exists admin_fee_commercial_lease_value numeric(14,4),
  add column if not exists effective_from date,
  add column if not exists effective_to date,
  add column if not exists is_promotion boolean not null default false;

create table if not exists public.dv_accounting_agent_fee_rules(
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  fee_plan_id uuid references public.dv_accounting_fee_plans(id),
  name text not null,
  effective_from date not null,
  effective_to date,
  desk_fee numeric(14,2),
  admin_fee_buy_sell_type text,
  admin_fee_buy_sell_value numeric(14,4),
  admin_fee_lease_type text,
  admin_fee_lease_value numeric(14,4),
  admin_fee_commercial_buy_sell_type text,
  admin_fee_commercial_buy_sell_value numeric(14,4),
  admin_fee_commercial_lease_type text,
  admin_fee_commercial_lease_value numeric(14,4),
  lead_fee_buy_sell_type text,
  lead_fee_buy_sell_value numeric(14,4),
  lead_fee_lease_type text,
  lead_fee_lease_value numeric(14,4),
  commission_split_percent numeric(7,4),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to >= effective_from)
);

create index if not exists idx_dv_agent_fee_rules_agent_dates
  on public.dv_accounting_agent_fee_rules(agent_id,effective_from,effective_to);

create table if not exists public.dv_accounting_commission_charges(
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references public.dv_accounting_commissions(id) on delete cascade,
  transaction_id uuid references public.dv_accounting_transactions(id),
  agent_id uuid references public.dv_accounting_agents(id),
  charge_type text not null,
  description text not null,
  amount numeric(14,2) not null default 0,
  source_rule_id uuid references public.dv_accounting_agent_fee_rules(id),
  created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_commission_cheques(
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.dv_accounting_companies(id),
  agent_id uuid not null references public.dv_accounting_agents(id),
  commission_id uuid references public.dv_accounting_commissions(id),
  cheque_number text,
  cheque_date date not null default current_date,
  gross_commission numeric(14,2) not null default 0,
  agent_share numeric(14,2) not null default 0,
  total_fees numeric(14,2) not null default 0,
  adjustments numeric(14,2) not null default 0,
  net_amount numeric(14,2) generated always as(agent_share-total_fees+adjustments) stored,
  status text not null default 'DRAFT' check(status in ('DRAFT','APPROVED','ISSUED','VOID')),
  issued_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_dv_commission_cheques_agent_date
  on public.dv_accounting_commission_cheques(agent_id,cheque_date);

create table if not exists public.dv_accounting_recurring_fee_rules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  name text not null,
  applies_to text not null check(applies_to in ('BROKERAGE','AGENT')),
  agent_id uuid references public.dv_accounting_agents(id) on delete cascade,
  category text,
  description text,
  amount numeric(14,2) not null default 0,
  hst_amount numeric(14,2) not null default 0,
  frequency text not null check(frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY','CUSTOM_DAYS')),
  interval_days integer,
  day_of_month integer,
  start_date date not null,
  end_date date,
  next_run_date date not null,
  branch_id uuid references public.dv_accounting_branches(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(amount >= 0),
  check(end_date is null or end_date >= start_date)
);

create index if not exists idx_dv_recurring_fee_rules_due
  on public.dv_accounting_recurring_fee_rules(company_id,next_run_date,active);

create table if not exists public.dv_accounting_recurring_fee_runs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  run_date date not null,
  status text not null default 'POSTED',
  created_at timestamptz not null default now(),
  unique(company_id,run_date)
);

alter table public.dv_accounting_agent_fee_rules enable row level security;
alter table public.dv_accounting_commission_charges enable row level security;
alter table public.dv_accounting_commission_cheques enable row level security;
alter table public.dv_accounting_recurring_fee_rules enable row level security;
alter table public.dv_accounting_recurring_fee_runs enable row level security;

do $$ declare t text; begin
 for t in select unnest(array[
  'dv_accounting_agent_fee_rules',
  'dv_accounting_commission_charges',
  'dv_accounting_commission_cheques',
  'dv_accounting_recurring_fee_rules',
  'dv_accounting_recurring_fee_runs'
 ]) loop
  execute format('drop policy if exists "authenticated access" on public.%I',t);
  execute format('create policy "authenticated access" on public.%I for all to authenticated using(true) with check(true)',t);
 end loop;
end $$;

-- Returns the active fee rule for an agent on a specific date.
create or replace function public.dv_accounting_get_agent_fee_rule(
  p_agent_id uuid,
  p_as_of date
) returns uuid
language sql stable security definer set search_path=public
as $$
  select r.id
  from public.dv_accounting_agent_fee_rules r
  where r.agent_id=p_agent_id
    and r.active
    and r.effective_from <= p_as_of
    and (r.effective_to is null or r.effective_to >= p_as_of)
  order by r.effective_from desc, r.created_at desc
  limit 1
$$;

-- Calculate the transaction fees that will be used when the agent commission is issued.
-- The result is informational; issuing the cheque snapshots the amounts into commission_charges.
create or replace function public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  a public.dv_accounting_agents%rowtype;
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 90;
  admin_type text;
  admin_value numeric := 0;
  lead_type text;
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
  desk_fee numeric := 0;
begin
  select * into a from public.dv_accounting_agents where id=p_agent_id;
  if not found then raise exception 'Agent not found'; end if;
  select * into t from public.dv_accounting_transactions where id=p_transaction_id;
  if not found then raise exception 'Transaction not found'; end if;

  select * into rule
  from public.dv_accounting_agent_fee_rules
  where agent_id=p_agent_id and active
    and effective_from<=p_as_of
    and (effective_to is null or effective_to>=p_as_of)
  order by effective_from desc,created_at desc limit 1;

  if rule.id is not null then
    split_pct:=coalesce(rule.commission_split_percent,split_pct);
    desk_fee:=coalesce(rule.desk_fee,0);
    if t.market_segment='COMMERCIAL' and t.side='LEASE' then
      admin_type:=coalesce(rule.admin_fee_commercial_lease_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_commercial_lease_value,0);
    elsif t.market_segment='COMMERCIAL' then
      admin_type:=coalesce(rule.admin_fee_commercial_buy_sell_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_commercial_buy_sell_value,0);
    elsif t.side='LEASE' then
      admin_type:=coalesce(rule.admin_fee_lease_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_lease_value,0);
    else
      admin_type:=coalesce(rule.admin_fee_buy_sell_type,'AMOUNT');
      admin_value:=coalesce(rule.admin_fee_buy_sell_value,0);
    end if;
    if t.side='LEASE' then
      lead_type:=coalesce(rule.lead_fee_lease_type,'AMOUNT');
      lead_value:=coalesce(rule.lead_fee_lease_value,0);
    else
      lead_type:=coalesce(rule.lead_fee_buy_sell_type,'AMOUNT');
      lead_value:=coalesce(rule.lead_fee_buy_sell_value,0);
    end if;
  else
    select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
    if fs.id is not null then
      if fs.fee_plan_id is not null then select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id; end if;
      split_pct:=coalesce(fs.commission_split_override_percent,plan.commission_split_percent,split_pct);
      desk_fee:=coalesce(fs.desk_fee_override,plan.desk_fee,0);
      if t.market_segment='COMMERCIAL' and t.side='LEASE' then
        admin_type:=coalesce(fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
      elsif t.market_segment='COMMERCIAL' then
        admin_type:=coalesce(fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
      elsif t.side='LEASE' then
        admin_type:=coalesce(fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
      else
        admin_type:=coalesce(fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
        admin_value:=coalesce(fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
      end if;
      if t.side='LEASE' then
        lead_type:=coalesce(fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
        lead_value:=coalesce(fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
      else
        lead_type:=coalesce(fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
        lead_value:=coalesce(fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
      end if;
    else
      split_pct:=coalesce(plan.commission_split_percent,split_pct);
      desk_fee:=coalesce(plan.desk_fee,0);
    end if;
  end if;

  agent_share:=round(coalesce(p_gross_commission,0)*split_pct/100,2);
  if admin_type='PERCENT' then admin_fee:=round(p_gross_commission*admin_value/100,2); else admin_fee:=round(admin_value,2); end if;
  if lead_type='PERCENT' then lead_fee:=round(p_gross_commission*lead_value/100,2); else lead_fee:=round(lead_value,2); end if;

  return jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'total_transaction_fees',round(admin_fee+lead_fee,2),
    'net_transaction_commission',round(agent_share-admin_fee-lead_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
end $$;

grant execute on function public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) to authenticated;

-- Issue a commission cheque and freeze the fee calculation at issuance.
create or replace function public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text default null,
  p_cheque_date date default current_date,
  p_adjustment numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  total_fees numeric(14,2);
  agent_share numeric(14,2);
begin
  select * into c from public.dv_accounting_commissions where id=p_commission_id for update;
  if not found then raise exception 'Commission record not found'; end if;
  if c.status='PAID' then raise exception 'Commission has already been paid'; end if;
  select * into t from public.dv_accounting_transactions where id=c.transaction_id;
  select * into agent from public.dv_accounting_agents where id=c.agent_id;
  if not found then raise exception 'Agent not found'; end if;

  calc:=public.dv_accounting_calculate_commission_fees(
    c.agent_id,c.transaction_id,coalesce(c.gross_commission,t.gross_commission,0),coalesce(t.transaction_date,p_cheque_date)
  );
  agent_share:=coalesce((calc->>'agent_share')::numeric,0);
  total_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);

  insert into public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,
    agent_share,total_fees,adjustments,status,issued_at,notes
  )
  values(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,
    coalesce(c.gross_commission,t.gross_commission,0),agent_share,total_fees,
    coalesce(p_adjustment,0),'ISSUED',now(),p_notes
  ) returning id into cheque_id;

  insert into public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,
    source_rule_id
  )
  select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end
  from jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
    )
  ) as x(charge_type text,description text,amount numeric);

  update public.dv_accounting_commissions
  set status='PAID',paid_date=p_cheque_date
  where id=c.id;

  return jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),
    'calculation',calc
  );
end $$;

grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) to authenticated;

-- One-click recurring processing. It creates brokerage expenses and agent charges for all rules due on the run date.
create or replace function public.dv_accounting_run_recurring_fees(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  r public.dv_accounting_recurring_fee_rules%rowtype;
  company uuid;
  created_count integer := 0;
  skipped_count integer := 0;
  period_end date;
begin
  for r in
    select * from public.dv_accounting_recurring_fee_rules
    where active and next_run_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_run_date,created_at
  loop
    company:=r.company_id;

    if r.applies_to='BROKERAGE' then
      insert into public.dv_accounting_expenses(company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status)
      values(company,p_run_date,'Recurring','RECURRING',r.description,r.amount,r.hst_amount,'OPEN','UNPAID');
      created_count:=created_count+1;
    else
      -- Agent recurring charges are kept as commission-style charges until collected/deducted.
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount
      )
      select null,null,r.agent_id,'RECURRING_FEE',coalesce(r.description,r.name),r.amount;
      created_count:=created_count+1;
    end if;

    update public.dv_accounting_recurring_fee_rules
    set next_run_date=
      case
        when frequency='MONTHLY' then (next_run_date + interval '1 month')::date
        when frequency='QUARTERLY' then (next_run_date + interval '3 months')::date
        when frequency='SEMI_ANNUALLY' then (next_run_date + interval '6 months')::date
        when frequency='ANNUALLY' then (next_run_date + interval '1 year')::date
        when frequency='CUSTOM_DAYS' then next_run_date + greatest(coalesce(interval_days,30),1)
      end
    where id=r.id;
  end loop;

  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count);
end $$;

grant execute on function public.dv_accounting_run_recurring_fees(date) to authenticated;


-- ============================================================
-- 0019_recurring_fee_cheque_application.sql
-- ============================================================

-- 0019: recurring fee idempotency and commission cheque application of outstanding agent recurring charges

alter table public.dv_accounting_commission_charges
  add column if not exists applied_to_cheque_id uuid references public.dv_accounting_commission_cheques(id),
  add column if not exists status text not null default 'OPEN'
    check(status in ('OPEN','APPLIED','VOID'));

create index if not exists idx_dv_commission_charges_agent_open
  on public.dv_accounting_commission_charges(agent_id,status,charge_type);

create or replace function public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text default null,
  p_cheque_date date default current_date,
  p_adjustment numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  transaction_fees numeric(14,2);
  recurring_fees numeric(14,2);
  total_fees numeric(14,2);
  agent_share numeric(14,2);
begin
  select * into c from public.dv_accounting_commissions where id=p_commission_id for update;
  if not found then raise exception 'Commission record not found'; end if;
  if c.status='PAID' then raise exception 'Commission has already been paid'; end if;
  select * into t from public.dv_accounting_transactions where id=c.transaction_id;
  select * into agent from public.dv_accounting_agents where id=c.agent_id;
  if not found then raise exception 'Agent not found'; end if;

  calc:=public.dv_accounting_calculate_commission_fees(
    c.agent_id,c.transaction_id,coalesce(c.gross_commission,t.gross_commission,0),coalesce(t.transaction_date,p_cheque_date)
  );
  agent_share:=coalesce((calc->>'agent_share')::numeric,0);
  transaction_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);

  select coalesce(sum(amount),0) into recurring_fees
  from public.dv_accounting_commission_charges
  where agent_id=c.agent_id
    and charge_type='RECURRING_FEE'
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  total_fees:=transaction_fees+recurring_fees;

  insert into public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,
    agent_share,total_fees,adjustments,status,issued_at,notes
  )
  values(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,
    coalesce(c.gross_commission,t.gross_commission,0),agent_share,total_fees,
    coalesce(p_adjustment,0),'ISSUED',now(),p_notes
  ) returning id into cheque_id;

  insert into public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,
    source_rule_id,status,applied_to_cheque_id
  )
  select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end,
         'APPLIED',cheque_id
  from jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
    )
  ) as x(charge_type text,description text,amount numeric)
  where x.amount<>0;

  update public.dv_accounting_commission_charges
  set status='APPLIED',applied_to_cheque_id=cheque_id
  where agent_id=c.agent_id
    and charge_type='RECURRING_FEE'
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  update public.dv_accounting_commissions
  set status='PAID',paid_date=p_cheque_date
  where id=c.id;

  return jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'transaction_fees',transaction_fees,
    'recurring_fees',recurring_fees,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),
    'calculation',calc
  );
end $$;

grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) to authenticated;

create or replace function public.dv_accounting_run_recurring_fees(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  r public.dv_accounting_recurring_fee_rules%rowtype;
  created_count integer := 0;
  skipped_count integer := 0;
  run_id uuid;
begin
  if exists(select 1 from public.dv_accounting_recurring_fee_runs where run_date=p_run_date) then
    return jsonb_build_object('run_date',p_run_date,'created_count',0,'skipped_count',1,'status','ALREADY_RUN');
  end if;

  insert into public.dv_accounting_recurring_fee_runs(company_id,run_date,status)
  select id,p_run_date,'POSTED'
  from public.dv_accounting_companies
  order by created_at
  limit 1
  returning id into run_id;

  if run_id is null then raise exception 'Create a company before running recurring fees'; end if;

  for r in
    select * from public.dv_accounting_recurring_fee_rules
    where active and next_run_date<=p_run_date
      and (end_date is null or end_date>=p_run_date)
    order by next_run_date,created_at
  loop
    if r.applies_to='BROKERAGE' then
      insert into public.dv_accounting_expenses(company_id,expense_date,vendor,category,description,amount,hst_amount,status,payment_status)
      values(r.company_id,p_run_date,'Recurring','RECURRING',r.description,r.amount,r.hst_amount,'OPEN','UNPAID');
    else
      insert into public.dv_accounting_commission_charges(
        commission_id,transaction_id,agent_id,charge_type,description,amount,status
      )
      values(null,null,r.agent_id,'RECURRING_FEE',coalesce(r.description,r.name),r.amount,'OPEN');
    end if;
    created_count:=created_count+1;

    update public.dv_accounting_recurring_fee_rules
    set next_run_date=
      case
        when frequency='MONTHLY' then (next_run_date + interval '1 month')::date
        when frequency='QUARTERLY' then (next_run_date + interval '3 months')::date
        when frequency='SEMI_ANNUALLY' then (next_run_date + interval '6 months')::date
        when frequency='ANNUALLY' then (next_run_date + interval '1 year')::date
        when frequency='CUSTOM_DAYS' then next_run_date + greatest(coalesce(interval_days,30),1)
      end
    where id=r.id;
  end loop;

  return jsonb_build_object('run_date',p_run_date,'created_count',created_count,'skipped_count',skipped_count,'run_id',run_id);
end $$;

grant execute on function public.dv_accounting_run_recurring_fees(date) to authenticated;


-- ============================================================
-- 0020_fee_type_validation.sql
-- ============================================================

-- 0020: promotion flag and fee type validation
alter table public.dv_accounting_agent_fee_rules
  add column if not exists is_promotion boolean not null default false;

alter table public.dv_accounting_fee_plans
  drop constraint if exists dv_accounting_fee_plans_admin_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_lease_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check,
  drop constraint if exists dv_accounting_fee_plans_admin_fee_commercial_lease_type_check;

alter table public.dv_accounting_fee_plans
  add constraint dv_accounting_fee_plans_admin_fee_buy_sell_type_check check(admin_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_lease_type_check check(admin_fee_lease_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check check(admin_fee_commercial_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_fee_plans_admin_fee_commercial_lease_type_check check(admin_fee_commercial_lease_type in ('AMOUNT','PERCENT'));

alter table public.dv_accounting_agent_fee_rules
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_lease_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_commercial_buy_sell_type_check,
  drop constraint if exists dv_accounting_agent_fee_rules_admin_fee_commercial_lease_type_check;

alter table public.dv_accounting_agent_fee_rules
  add constraint dv_accounting_agent_fee_rules_admin_fee_buy_sell_type_check check(admin_fee_buy_sell_type is null or admin_fee_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_lease_type_check check(admin_fee_lease_type is null or admin_fee_lease_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_commercial_buy_sell_type_check check(admin_fee_commercial_buy_sell_type is null or admin_fee_commercial_buy_sell_type in ('AMOUNT','PERCENT')),
  add constraint dv_accounting_agent_fee_rules_admin_fee_commercial_lease_type_check check(admin_fee_commercial_lease_type is null or admin_fee_commercial_lease_type in ('AMOUNT','PERCENT'));



-- ============================================================
-- 0021_fee_rule_plan_inheritance.sql
-- ============================================================

-- 0021: fee-rule inheritance from assigned fee plan
create or replace function public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 90;
  desk_fee numeric := 0;
  admin_type text := 'AMOUNT';
  admin_value numeric := 0;
  lead_type text := 'AMOUNT';
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
begin
  select * into t from public.dv_accounting_transactions where id=p_transaction_id;
  if not found then raise exception 'Transaction not found'; end if;

  select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
  if fs.fee_plan_id is not null then
    select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
  end if;

  select * into rule
  from public.dv_accounting_agent_fee_rules
  where agent_id=p_agent_id and active
    and effective_from<=p_as_of
    and (effective_to is null or effective_to>=p_as_of)
  order by effective_from desc,created_at desc limit 1;

  split_pct:=coalesce(
    rule.commission_split_percent,
    fs.commission_split_override_percent,
    plan.commission_split_percent,
    90
  );
  desk_fee:=coalesce(
    rule.desk_fee,
    fs.desk_fee_override,
    plan.desk_fee,
    0
  );

  if t.market_segment='COMMERCIAL' and t.side='LEASE' then
    admin_type:=coalesce(rule.admin_fee_commercial_lease_type,fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_commercial_lease_value,fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
  elsif t.market_segment='COMMERCIAL' then
    admin_type:=coalesce(rule.admin_fee_commercial_buy_sell_type,fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_commercial_buy_sell_value,fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
  elsif t.side='LEASE' then
    admin_type:=coalesce(rule.admin_fee_lease_type,fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_lease_value,fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
  else
    admin_type:=coalesce(rule.admin_fee_buy_sell_type,fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
    admin_value:=coalesce(rule.admin_fee_buy_sell_value,fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
  end if;

  if t.side='LEASE' then
    lead_type:=coalesce(rule.lead_fee_lease_type,fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
    lead_value:=coalesce(rule.lead_fee_lease_value,fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
  else
    lead_type:=coalesce(rule.lead_fee_buy_sell_type,fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
    lead_value:=coalesce(rule.lead_fee_buy_sell_value,fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
  end if;

  agent_share:=round(coalesce(p_gross_commission,0)*split_pct/100,2);
  if admin_type='PERCENT' then admin_fee:=round(coalesce(p_gross_commission,0)*admin_value/100,2); else admin_fee:=round(admin_value,2); end if;
  if lead_type='PERCENT' then lead_fee:=round(coalesce(p_gross_commission,0)*lead_value/100,2); else lead_fee:=round(lead_value,2); end if;

  return jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'total_transaction_fees',round(admin_fee+lead_fee,2),
    'net_transaction_commission',round(agent_share-admin_fee-lead_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
end $$;

grant execute on function public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) to authenticated;



-- ============================================================
-- -- 0022_fee_schema_repair.sql
-- ============================================================

-- 0022: repair fee-plan schema for databases installed before migrations 0018-0021
-- Safe/idempotent: adds only missing fee-plan and agent-fee columns required by the current UI.

alter table public.dv_accounting_fee_plans
  add column if not exists admin_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_lease_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_buy_sell_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists admin_fee_commercial_lease_type text not null default 'AMOUNT',
  add column if not exists admin_fee_commercial_lease_value numeric(14,4) not null default 0,
  add column if not exists lead_fee_buy_sell_type text not null default 'AMOUNT',
  add column if not exists lead_fee_buy_sell_value numeric(14,4) not null default 0,
  add column if not exists lead_fee_lease_type text not null default 'AMOUNT',
  add column if not exists lead_fee_lease_value numeric(14,4) not null default 0;

alter table public.dv_accounting_agent_fee_settings
  add column if not exists lead_fee_buy_sell_type text,
  add column if not exists lead_fee_buy_sell_value numeric(14,4),
  add column if not exists lead_fee_lease_type text,
  add column if not exists lead_fee_lease_value numeric(14,4),
  add column if not exists admin_fee_buy_sell_type text,
  add column if not exists admin_fee_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_lease_type text,
  add column if not exists admin_fee_lease_value numeric(14,4),
  add column if not exists admin_fee_commercial_buy_sell_type text,
  add column if not exists admin_fee_commercial_buy_sell_value numeric(14,4),
  add column if not exists admin_fee_commercial_lease_type text,
  add column if not exists admin_fee_commercial_lease_value numeric(14,4),
  add column if not exists effective_from date,
  add column if not exists effective_to date,
  add column if not exists is_promotion boolean not null default false;

alter table public.dv_accounting_transactions
  add column if not exists market_segment text not null default 'RESIDENTIAL';

do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conname='dv_accounting_fee_plans_admin_fee_buy_sell_type_check'
  ) then
    alter table public.dv_accounting_fee_plans
      add constraint dv_accounting_fee_plans_admin_fee_buy_sell_type_check
      check(admin_fee_buy_sell_type in ('AMOUNT','PERCENT'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname='dv_accounting_fee_plans_admin_fee_lease_type_check'
  ) then
    alter table public.dv_accounting_fee_plans
      add constraint dv_accounting_fee_plans_admin_fee_lease_type_check
      check(admin_fee_lease_type in ('AMOUNT','PERCENT'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname='dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check'
  ) then
    alter table public.dv_accounting_fee_plans
      add constraint dv_accounting_fee_plans_admin_fee_commercial_buy_sell_type_check
      check(admin_fee_commercial_buy_sell_type in ('AMOUNT','PERCENT'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname='dv_accounting_fee_plans_admin_fee_commercial_lease_type_check'
  ) then
    alter table public.dv_accounting_fee_plans
      add constraint dv_accounting_fee_plans_admin_fee_commercial_lease_type_check
      check(admin_fee_commercial_lease_type in ('AMOUNT','PERCENT'));
  end if;
end $$;

-- The new commission/recurring tables are also created here so an older database
-- can be repaired in one pass.
create table if not exists public.dv_accounting_agent_fee_rules(
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  fee_plan_id uuid references public.dv_accounting_fee_plans(id),
  name text not null,
  effective_from date not null,
  effective_to date,
  desk_fee numeric(14,2),
  admin_fee_buy_sell_type text,
  admin_fee_buy_sell_value numeric(14,4),
  admin_fee_lease_type text,
  admin_fee_lease_value numeric(14,4),
  admin_fee_commercial_buy_sell_type text,
  admin_fee_commercial_buy_sell_value numeric(14,4),
  admin_fee_commercial_lease_type text,
  admin_fee_commercial_lease_value numeric(14,4),
  lead_fee_buy_sell_type text,
  lead_fee_buy_sell_value numeric(14,4),
  lead_fee_lease_type text,
  lead_fee_lease_value numeric(14,4),
  commission_split_percent numeric(7,4),
  notes text,
  is_promotion boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to >= effective_from)
);

create table if not exists public.dv_accounting_commission_charges(
  id uuid primary key default gen_random_uuid(),
  commission_id uuid references public.dv_accounting_commissions(id) on delete cascade,
  transaction_id uuid references public.dv_accounting_transactions(id),
  agent_id uuid references public.dv_accounting_agents(id),
  charge_type text not null,
  description text not null,
  amount numeric(14,2) not null default 0,
  source_rule_id uuid references public.dv_accounting_agent_fee_rules(id),
  applied_to_cheque_id uuid,
  status text not null default 'OPEN',
  created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_commission_cheques(
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.dv_accounting_companies(id),
  agent_id uuid not null references public.dv_accounting_agents(id),
  commission_id uuid references public.dv_accounting_commissions(id),
  cheque_number text,
  cheque_date date not null default current_date,
  gross_commission numeric(14,2) not null default 0,
  agent_share numeric(14,2) not null default 0,
  total_fees numeric(14,2) not null default 0,
  adjustments numeric(14,2) not null default 0,
  net_amount numeric(14,2) generated always as(agent_share-total_fees+adjustments) stored,
  status text not null default 'DRAFT',
  issued_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_recurring_fee_rules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  name text not null,
  applies_to text not null check(applies_to in ('BROKERAGE','AGENT')),
  agent_id uuid references public.dv_accounting_agents(id) on delete cascade,
  category text,
  description text,
  amount numeric(14,2) not null default 0,
  hst_amount numeric(14,2) not null default 0,
  frequency text not null check(frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY','CUSTOM_DAYS')),
  interval_days integer,
  day_of_month integer,
  start_date date not null,
  end_date date,
  next_run_date date not null,
  branch_id uuid references public.dv_accounting_branches(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check(amount >= 0),
  check(end_date is null or end_date >= start_date)
);

create table if not exists public.dv_accounting_recurring_fee_runs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  run_date date not null,
  status text not null default 'POSTED',
  created_at timestamptz not null default now(),
  unique(company_id,run_date)
);

create index if not exists idx_dv_agent_fee_rules_agent_dates
  on public.dv_accounting_agent_fee_rules(agent_id,effective_from,effective_to);

create index if not exists idx_dv_commission_charges_agent_open
  on public.dv_accounting_commission_charges(agent_id,status,charge_type);

create index if not exists idx_dv_commission_cheques_agent_date
  on public.dv_accounting_commission_cheques(agent_id,cheque_date);

create index if not exists idx_dv_recurring_fee_rules_due
  on public.dv_accounting_recurring_fee_rules(company_id,next_run_date,active);



-- ============================================================
-- 0023_agent_recurring_services.sql
-- ============================================================

-- 0023: recurring agent billing plans, desk-fee frequency and added-value services

alter table public.dv_accounting_fee_plans
  add column if not exists desk_fee_frequency text not null default 'MONTHLY'
    check(desk_fee_frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY'));

alter table public.dv_accounting_agent_fee_settings
  add column if not exists desk_fee_frequency text;

alter table public.dv_accounting_agent_fee_rules
  add column if not exists desk_fee_frequency text;

-- Catalog of optional services the brokerage can offer agents.
create table if not exists public.dv_accounting_agent_service_catalog(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  name text not null,
  description text,
  default_amount numeric(14,2) not null default 0,
  default_hst_amount numeric(14,2) not null default 0,
  default_frequency text not null default 'MONTHLY'
    check(default_frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id,name)
);

-- One row per agent/service subscription. next_charge_date is the source of truth
-- for the next time that specific agent is charged.
create table if not exists public.dv_accounting_agent_service_subscriptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid not null references public.dv_accounting_agents(id) on delete cascade,
  service_id uuid references public.dv_accounting_agent_service_catalog(id) on delete set null,
  service_type text not null default 'ADD_ON'
    check(service_type in ('DESK_FEE','ADD_ON')),
  name text not null,
  amount numeric(14,2) not null default 0,
  hst_amount numeric(14,2) not null default 0,
  frequency text not null
    check(frequency in ('MONTHLY','QUARTERLY','SEMI_ANNUALLY','ANNUALLY')),
  start_date date not null,
  end_date date,
  next_charge_date date not null,
  active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  check(amount >= 0),
  check(end_date is null or end_date >= start_date)
);

create index if not exists idx_dv_agent_service_subscriptions_due
  on public.dv_accounting_agent_service_subscriptions(company_id,next_charge_date,active);

create index if not exists idx_dv_agent_service_subscriptions_agent
  on public.dv_accounting_agent_service_subscriptions(agent_id,active);

-- Seed/maintain a desk-fee subscription for an agent. Existing active subscription
-- is left alone so changing a plan does not unexpectedly change the next charge.
create or replace function public.dv_accounting_sync_agent_desk_fee_subscription(
  p_agent_id uuid,
  p_start_date date default current_date
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  a public.dv_accounting_agents%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  sub public.dv_accounting_agent_service_subscriptions%rowtype;
  sid uuid;
  freq text;
  fee numeric;
begin
  select * into a from public.dv_accounting_agents where id=p_agent_id;
  if not found then raise exception 'Agent not found'; end if;

  select * into fs from public.dv_accounting_agent_fee_settings where agent_id=p_agent_id;
  if fs.id is not null and fs.fee_plan_id is not null then
    select * into plan from public.dv_accounting_fee_plans where id=fs.fee_plan_id;
  end if;

  if plan.id is null then return null; end if;

  fee:=coalesce(fs.desk_fee_override,plan.desk_fee,0);
  freq:=coalesce(fs.desk_fee_frequency,plan.desk_fee_frequency,'MONTHLY');

  select * into sub
  from public.dv_accounting_agent_service_subscriptions
  where agent_id=p_agent_id and service_type='DESK_FEE' and active
  order by created_at desc limit 1;

  if sub.id is not null then
    return sub.id;
  end if;

  insert into public.dv_accounting_agent_service_subscriptions(
    company_id,agent_id,service_type,name,amount,hst_amount,frequency,
    start_date,next_charge_date,active,notes
  )
  values(
    a.company_id,a.id,'DESK_FEE','Desk Fee',fee,0,freq,
    p_start_date,p_start_date,true,'Created from assigned fee plan'
  )
  returning id into sid;

  return sid;
end $$;

grant execute on function public.dv_accounting_sync_agent_desk_fee_subscription(uuid,date) to authenticated;

-- One-click billing for agent desk fees and added-value services.
-- Each subscription advances its own next_charge_date, so monthly/yearly
-- services never lose their individual billing anniversary.
create or replace function public.dv_accounting_run_agent_service_billing(
  p_run_date date default current_date
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  s public.dv_accounting_agent_service_subscriptions%rowtype;
  created_count integer := 0;
  company uuid;
begin
  for s in
    select * from public.dv_accounting_agent_service_subscriptions
    where active
      and next_charge_date <= p_run_date
      and (end_date is null or end_date >= p_run_date)
    order by next_charge_date,created_at
  loop
    insert into public.dv_accounting_commission_charges(
      commission_id,transaction_id,agent_id,charge_type,description,amount,status
    )
    values(
      null,null,s.agent_id,
      case when s.service_type='DESK_FEE' then 'DESK_FEE' else 'ADD_ON_SERVICE' end,
      s.name,s.amount,'OPEN'
    );

    created_count:=created_count+1;

    update public.dv_accounting_agent_service_subscriptions
    set next_charge_date=
      case
        when frequency='MONTHLY' then (next_charge_date + interval '1 month')::date
        when frequency='QUARTERLY' then (next_charge_date + interval '3 months')::date
        when frequency='SEMI_ANNUALLY' then (next_charge_date + interval '6 months')::date
        when frequency='ANNUALLY' then (next_charge_date + interval '1 year')::date
      end,
      active=case
        when end_date is not null and
             (case
               when frequency='MONTHLY' then (next_charge_date + interval '1 month')::date
               when frequency='QUARTERLY' then (next_charge_date + interval '3 months')::date
               when frequency='SEMI_ANNUALLY' then (next_charge_date + interval '6 months')::date
               when frequency='ANNUALLY' then (next_charge_date + interval '1 year')::date
             end) > end_date then false
        else active
      end
    where id=s.id;
  end loop;

  return jsonb_build_object(
    'run_date',p_run_date,
    'created_count',created_count
  );
end $$;

grant execute on function public.dv_accounting_run_agent_service_billing(date) to authenticated;


-- ============================================================
-- 0024_commission_cheque_service_charges.sql
-- ============================================================

-- 0024: include desk fees and added-value service charges in commission cheques

create or replace function public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text default null,
  p_cheque_date date default current_date,
  p_adjustment numeric default 0,
  p_notes text default null
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  calc jsonb;
  cheque_id uuid;
  transaction_fees numeric(14,2);
  recurring_fees numeric(14,2);
  service_fees numeric(14,2);
  total_fees numeric(14,2);
  agent_share numeric(14,2);
begin
  select * into c from public.dv_accounting_commissions where id=p_commission_id for update;
  if not found then raise exception 'Commission record not found'; end if;
  if c.status='PAID' then raise exception 'Commission has already been paid'; end if;

  select * into t from public.dv_accounting_transactions where id=c.transaction_id;
  if not found then raise exception 'Transaction not found'; end if;

  calc:=public.dv_accounting_calculate_commission_fees(
    c.agent_id,c.transaction_id,coalesce(c.gross_commission,t.gross_commission,0),
    coalesce(t.transaction_date,p_cheque_date)
  );

  agent_share:=coalesce((calc->>'agent_share')::numeric,0);
  transaction_fees:=coalesce((calc->>'admin_fee')::numeric,0)+coalesce((calc->>'lead_fee')::numeric,0);

  select coalesce(sum(amount),0) into recurring_fees
  from public.dv_accounting_commission_charges
  where agent_id=c.agent_id
    and charge_type='RECURRING_FEE'
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  select coalesce(sum(amount),0) into service_fees
  from public.dv_accounting_commission_charges
  where agent_id=c.agent_id
    and charge_type in ('DESK_FEE','ADD_ON_SERVICE')
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  total_fees:=transaction_fees+recurring_fees+service_fees;

  insert into public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,
    agent_share,total_fees,adjustments,status,issued_at,notes
  )
  values(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,
    coalesce(c.gross_commission,t.gross_commission,0),agent_share,total_fees,
    coalesce(p_adjustment,0),'ISSUED',now(),p_notes
  ) returning id into cheque_id;

  insert into public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,
    source_rule_id,status,applied_to_cheque_id
  )
  select c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         case when x.charge_type in ('ADMIN_FEE','LEAD_FEE') then (calc->>'fee_rule_id')::uuid else null end,
         'APPLIED',cheque_id
  from jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',coalesce((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',coalesce((calc->>'lead_fee')::numeric,0))
    )
  ) as x(charge_type text,description text,amount numeric)
  where x.amount<>0;

  update public.dv_accounting_commission_charges
  set status='APPLIED',applied_to_cheque_id=cheque_id
  where agent_id=c.agent_id
    and charge_type in ('RECURRING_FEE','DESK_FEE','ADD_ON_SERVICE')
    and status='OPEN'
    and applied_to_cheque_id is null
    and created_at::date<=p_cheque_date;

  update public.dv_accounting_commissions
  set status='PAID',paid_date=p_cheque_date
  where id=c.id;

  return jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'transaction_fees',transaction_fees,
    'recurring_fees',recurring_fees,
    'service_fees',service_fees,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+coalesce(p_adjustment,0),
    'calculation',calc
  );
end $$;

grant execute on function public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) to authenticated;



-- ============================================================
-- 0025_roles_personnel_documents.sql
-- ============================================================

-- 0025: roles, permissions, employee/agent headshots and secure personnel documents

alter table public.dv_accounting_agents
  add column if not exists headshot_path text;

alter table public.dv_accounting_employees
  add column if not exists headshot_path text;

create table if not exists public.dv_accounting_user_profiles(
  user_id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references public.dv_accounting_companies(id) on delete cascade,
  display_name text,
  role text not null default 'STAFF'
    check(role in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_role_permissions(
  role text primary key
    check(role in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER')),
  permissions jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.dv_accounting_role_permissions(role,permissions) values
('SUPERADMIN','{"agents":"full","staff":"full","documents":"full","fees":"full","accounting":"full","settings":"full","users":"full"}'),
('ADMIN','{"agents":"full","staff":"full","documents":"full","fees":"full","accounting":"full","settings":"limited","users":"manage"}'),
('MANAGER','{"agents":"edit","staff":"edit","documents":"manage","fees":"view","accounting":"view","settings":"none","users":"none"}'),
('ACCOUNTANT','{"agents":"view","staff":"view","documents":"view","fees":"full","accounting":"full","settings":"view","users":"none"}'),
('STAFF','{"agents":"view","staff":"view","documents":"limited","fees":"none","accounting":"limited","settings":"none","users":"none"}'),
('VIEWER','{"agents":"view","staff":"view","documents":"none","fees":"none","accounting":"view","settings":"none","users":"none"}')
on conflict(role) do nothing;

create or replace function public.dv_accounting_current_user_role()
returns text
language sql stable security definer set search_path=public
as $$
  select coalesce(
    (select role from public.dv_accounting_user_profiles where user_id=auth.uid() and active),
    case
      when coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),'')='superadmin' then 'SUPERADMIN'
      when coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),'')='admin' then 'ADMIN'
      else 'STAFF'
    end
  )
$$;

create or replace function public.dv_accounting_can_manage_personnel()
returns boolean
language sql stable security definer set search_path=public
as $$
 select public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
$$;

insert into public.dv_accounting_user_profiles(user_id,company_id,display_name,role)
select u.id,(select id from public.dv_accounting_companies order by created_at limit 1),
       coalesce(u.raw_user_meta_data->>'full_name',u.email),
       case
         when u.raw_app_meta_data->>'role'='superadmin' then 'SUPERADMIN'
         when u.raw_app_meta_data->>'role'='admin' then 'ADMIN'
         else 'STAFF'
       end
from auth.users u
on conflict(user_id) do nothing;

create table if not exists public.dv_accounting_personnel_documents(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid references public.dv_accounting_agents(id) on delete cascade,
  employee_id uuid references public.dv_accounting_employees(id) on delete cascade,
  document_type text not null,
  document_name text not null,
  storage_path text not null,
  mime_type text,
  file_size bigint,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(((agent_id is not null)::int + (employee_id is not null)::int)=1)
);

create index if not exists idx_dv_personnel_docs_agent on public.dv_accounting_personnel_documents(agent_id);
create index if not exists idx_dv_personnel_docs_employee on public.dv_accounting_personnel_documents(employee_id);

alter table public.dv_accounting_user_profiles enable row level security;
alter table public.dv_accounting_role_permissions enable row level security;
alter table public.dv_accounting_personnel_documents enable row level security;

drop policy if exists "user profiles access" on public.dv_accounting_user_profiles;
create policy "user profiles access" on public.dv_accounting_user_profiles
for all to authenticated
using(user_id=auth.uid() or public.dv_accounting_can_manage_personnel())
with check(user_id=auth.uid() or public.dv_accounting_can_manage_personnel());

drop policy if exists "role permissions read" on public.dv_accounting_role_permissions;
create policy "role permissions read" on public.dv_accounting_role_permissions
for select to authenticated using(true);

drop policy if exists "role permissions manage" on public.dv_accounting_role_permissions;
create policy "role permissions manage" on public.dv_accounting_role_permissions
for all to authenticated
using(public.dv_accounting_current_user_role()='SUPERADMIN')
with check(public.dv_accounting_current_user_role()='SUPERADMIN');

drop policy if exists "personnel documents access" on public.dv_accounting_personnel_documents;
create policy "personnel documents access" on public.dv_accounting_personnel_documents
for all to authenticated
using(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'))
with check(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'));

-- Private bucket for personnel files.
insert into storage.buckets(id,name,public)
values('dv-personnel','dv-personnel',false)
on conflict(id) do update set public=false;

drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read" on storage.objects
for select to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'));

drop policy if exists "dv personnel upload" on storage.objects;
create policy "dv personnel upload" on storage.objects
for insert to authenticated
with check(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "dv personnel update" on storage.objects;
create policy "dv personnel update" on storage.objects
for update to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "dv personnel delete" on storage.objects;
create policy "dv personnel delete" on storage.objects
for delete to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN'));

