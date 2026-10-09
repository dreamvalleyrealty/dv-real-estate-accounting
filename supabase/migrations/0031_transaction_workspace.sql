-- 0031_transaction_workspace.sql
-- Six-tab deal entry, reusable contacts/brokerages, trust deposits, commissions and agent fee snapshots.

alter table public.dv_accounting_transactions
  add column if not exists listing_id uuid,
  add column if not exists is_own_listing boolean not null default false,
  add column if not exists street_number text,
  add column if not exists street_name text,
  add column if not exists unit_number text,
  add column if not exists city text,
  add column if not exists province text default 'ON',
  add column if not exists postal_code text,
  add column if not exists offer_date date,
  add column if not exists firm_date date,
  add column if not exists close_date date,
  add column if not exists entry_date date,
  add column if not exists finalized_date date,
  add column if not exists agent_id uuid;

create table if not exists public.dv_accounting_contacts (
 id uuid primary key default gen_random_uuid(),
 first_name text not null default '',
 last_name text not null default '',
 company_name text,
 email text,
 phone text,
 fax text,
 address text,
 unit text,
 city text,
 province text default 'ON',
 postal_code text,
 contact_type text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_external_brokerages (
 id uuid primary key default gen_random_uuid(),
 company_name text not null,
 phone text,
 fax text,
 address text,
 unit text,
 city text,
 province text default 'ON',
 postal_code text,
 billing_email text,
 charges_hst boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_conditions (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
 item_type text not null default 'CONDITION' check(item_type in ('CONDITION','FILE')),
 description text not null,
 due_date date,
 met_date date,
 notes text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_people (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
 contact_id uuid references public.dv_accounting_contacts(id) on delete set null,
 person_type text not null default 'BUYER',
 first_name text,
 last_name text,
 company_name text,
 email text,
 phone text,
 fax text,
 address text,
 unit text,
 city text,
 province text default 'ON',
 postal_code text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_outside_brokers (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
 brokerage_id uuid references public.dv_accounting_external_brokerages(id) on delete set null,
 company_name text,
 phone text,
 fax text,
 agent_name text,
 agent_email text,
 address text,
 unit text,
 city text,
 province text default 'ON',
 postal_code text,
 billing_email text,
 charges_hst boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_trust (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
 we_hold_deposit text not null default 'YES' check(we_hold_deposit in ('YES','NO')),
 held_by text,
 received text not null default 'NO' check(received in ('YES','NO')),
 deposit_date date,
 received_from text,
 amount numeric(14,2) not null default 0,
 trust_bank_account_id uuid,
 earns_interest text not null default 'NO' check(earns_interest in ('YES','NO')),
 payment_type text not null default 'CHEQUE',
 reference_number text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_commissions (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
 side text not null check(side in ('LISTING','BUYER')),
 calculation_type text not null default 'PERCENT' check(calculation_type in ('PERCENT','AMOUNT')),
 rate numeric(9,4) not null default 0,
 amount numeric(14,2) not null default 0,
 hst_rate numeric(6,3) not null default 13,
 hst_amount numeric(14,2) not null default 0,
 settlement_direction text not null default 'RECEIVABLE' check(settlement_direction in ('RECEIVABLE','PAYABLE')),
 brokerage_id uuid references public.dv_accounting_external_brokerages(id) on delete set null,
 notes text,
 created_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_transaction_agent_info (
 id uuid primary key default gen_random_uuid(),
 transaction_id uuid not null unique references public.dv_accounting_transactions(id) on delete cascade,
 agent_id uuid,
 split_percent numeric(7,3) not null default 90,
 admin_fee numeric(14,2) not null default 0,
 lead_fee numeric(14,2) not null default 0,
 desk_fee numeric(14,2) not null default 0,
 other_outstanding_fees numeric(14,2) not null default 0,
 agent_gross numeric(14,2) not null default 0,
 net_payable numeric(14,2) not null default 0,
 notes text,
 created_at timestamptz not null default now()
);

do $$
declare t text;
begin
 foreach t in array array[
  'dv_accounting_contacts',
  'dv_accounting_external_brokerages',
  'dv_accounting_transaction_conditions',
  'dv_accounting_transaction_people',
  'dv_accounting_transaction_outside_brokers',
  'dv_accounting_transaction_trust',
  'dv_accounting_transaction_commissions',
  'dv_accounting_transaction_agent_info'
 ] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('drop policy if exists %I on public.%I',t||' authenticated access',t);
  execute format('create policy %I on public.%I for all to authenticated using (true) with check (true)',t||' authenticated access',t);
 end loop;
end $$;

create index if not exists dv_tx_conditions_transaction_idx on public.dv_accounting_transaction_conditions(transaction_id);
create index if not exists dv_tx_people_transaction_idx on public.dv_accounting_transaction_people(transaction_id);
create index if not exists dv_tx_outside_brokers_transaction_idx on public.dv_accounting_transaction_outside_brokers(transaction_id);
create index if not exists dv_tx_commissions_transaction_idx on public.dv_accounting_transaction_commissions(transaction_id);
create index if not exists dv_tx_trust_transaction_idx on public.dv_accounting_transaction_trust(transaction_id);
create index if not exists dv_tx_contacts_email_idx on public.dv_accounting_contacts(lower(email));
create index if not exists dv_tx_brokerage_name_idx on public.dv_accounting_external_brokerages(lower(company_name));
