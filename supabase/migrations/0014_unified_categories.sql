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
