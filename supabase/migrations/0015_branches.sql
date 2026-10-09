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
