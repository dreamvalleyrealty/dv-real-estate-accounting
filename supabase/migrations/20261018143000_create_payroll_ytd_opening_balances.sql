create table if not exists public.dv_accounting_payroll_ytd_opening_balances (
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
 employee_id uuid not null references public.dv_accounting_employees(id) on delete cascade,
 tax_year integer not null check (tax_year between 2000 and 2200),
 source_type text not null default 'PAYROLL_SUMMARY' check (source_type in ('PAYROLL_SUMMARY','PAYSTUBS','T4_SUMMARY','FULL_EXPORT','MANUAL')),
 source_reference text,
 prior_gross_pay numeric(14,2) not null default 0 check (prior_gross_pay >= 0),
 prior_income_tax numeric(14,2) not null default 0 check (prior_income_tax >= 0),
 prior_cpp numeric(14,2) not null default 0 check (prior_cpp >= 0),
 prior_cpp2 numeric(14,2) not null default 0 check (prior_cpp2 >= 0),
 prior_ei numeric(14,2) not null default 0 check (prior_ei >= 0),
 prior_employer_cpp numeric(14,2) not null default 0 check (prior_employer_cpp >= 0),
 prior_employer_cpp2 numeric(14,2) not null default 0 check (prior_employer_cpp2 >= 0),
 prior_employer_ei numeric(14,2) not null default 0 check (prior_employer_ei >= 0),
 prior_net_pay numeric(14,2) not null default 0,
 prior_pay_periods integer not null default 0 check (prior_pay_periods >= 0),
 notes text,
 imported_by uuid references auth.users(id) on delete set null,
 imported_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(employee_id,tax_year)
);
create index if not exists dv_accounting_payroll_ytd_opening_year_idx on public.dv_accounting_payroll_ytd_opening_balances(company_id,tax_year);
alter table public.dv_accounting_payroll_ytd_opening_balances enable row level security;
drop policy if exists payroll_ytd_opening_select on public.dv_accounting_payroll_ytd_opening_balances;
drop policy if exists payroll_ytd_opening_write on public.dv_accounting_payroll_ytd_opening_balances;
create policy payroll_ytd_opening_select on public.dv_accounting_payroll_ytd_opening_balances
 for select to authenticated using (public.dv_accounting_has_any_permission_all_scope(array['staff.salary.view','payroll.calculate','payroll.approve','reports.view']));
create policy payroll_ytd_opening_write on public.dv_accounting_payroll_ytd_opening_balances
 for all to authenticated using (public.dv_accounting_has_any_permission_all_scope(array['payroll.calculate','payroll.approve','staff.edit']))
 with check (public.dv_accounting_has_any_permission_all_scope(array['payroll.calculate','payroll.approve','staff.edit']));
comment on table public.dv_accounting_payroll_ytd_opening_balances is 'Imported historical payroll opening balances only. Never post these rows as payroll runs or accounting journal entries. One employee/year row prevents duplicate opening balances.';
