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
