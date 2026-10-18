-- Annual tax-slip setup and draft records. Run in Supabase SQL Editor / migration runner.
create table if not exists public.dv_accounting_tax_years (
 id uuid primary key default gen_random_uuid(),
 tax_year integer not null unique check (tax_year between 2000 and 2200),
 status text not null default 'SETUP' check (status in ('SETUP','DATA_REVIEW','READY','RELEASED','CLOSED')),
 updated_by uuid null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.dv_accounting_tax_slips (
 id uuid primary key default gen_random_uuid(),
 tax_year integer not null references public.dv_accounting_tax_years(tax_year) on delete restrict,
 slip_type text not null check (slip_type in ('T4','T4A')),
 recipient_user_id uuid null,
 recipient_employee_id uuid null,
 recipient_agent_id uuid null,
 recipient_name text,
 status text not null default 'DRAFT' check (status in ('MISSING_DATA','DRAFT','READY_FOR_REVIEW','RELEASED','SUPERSEDED')),
 reportable_amount numeric(14,2),
 tax_withheld numeric(14,2),
 source_snapshot jsonb not null default '{}'::jsonb,
 released_at timestamptz,
 released_by uuid,
 created_by uuid,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(tax_year,slip_type,recipient_user_id),
 check (
  (slip_type='T4' and recipient_agent_id is null) or
  (slip_type='T4A' and recipient_employee_id is null)
 )
);
create index if not exists dv_accounting_tax_slips_year_type_idx on public.dv_accounting_tax_slips(tax_year,slip_type,status);
alter table public.dv_accounting_tax_years enable row level security;
alter table public.dv_accounting_tax_slips enable row level security;
-- Intentionally no client policies yet: tax slips contain sensitive personal/tax data.
-- Add role-checked admin policies and recipient-specific SELECT policies before enabling portal access.
