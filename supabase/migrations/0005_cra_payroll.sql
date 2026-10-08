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
