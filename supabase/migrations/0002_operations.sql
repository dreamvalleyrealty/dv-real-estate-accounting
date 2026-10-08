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