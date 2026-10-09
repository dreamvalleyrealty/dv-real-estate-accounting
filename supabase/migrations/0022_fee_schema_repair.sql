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

alter table public.dv_accounting_agent_fee_rules
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
