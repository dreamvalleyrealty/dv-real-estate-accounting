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