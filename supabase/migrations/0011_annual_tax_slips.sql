-- Annual T4/T4A slip records and controlled release.
create table if not exists public.dv_accounting_tax_slips (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  tax_year integer not null check (tax_year between 2000 and 2200),
  slip_type text not null check (slip_type in ('T4','T4A')),
  employee_id uuid references public.dv_accounting_employees(id) on delete restrict,
  agent_id uuid references public.dv_accounting_agents(id) on delete restrict,
  recipient_user_id uuid,
  status text not null default 'draft' check (status in ('draft','review','released','cancelled')),
  recipient_name text,
  recipient_email text,
  boxes jsonb not null default '{}'::jsonb,
  source_summary jsonb not null default '{}'::jsonb,
  notes text,
  released_at timestamptz,
  released_by uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dv_accounting_tax_slips_person_type_check check (
    (slip_type = 'T4' and employee_id is not null and agent_id is null)
    or (slip_type = 'T4A' and agent_id is not null and employee_id is null)
  ),
  constraint dv_accounting_tax_slips_year_person_unique unique (tax_year, slip_type, employee_id, agent_id)
);
create index if not exists dv_accounting_tax_slips_year_type_idx
  on public.dv_accounting_tax_slips (tax_year, slip_type, status);
create index if not exists dv_accounting_tax_slips_recipient_user_idx
  on public.dv_accounting_tax_slips (recipient_user_id, tax_year);
alter table public.dv_accounting_tax_slips enable row level security;
drop policy if exists "tax slips admin manage" on public.dv_accounting_tax_slips;
create policy "tax slips admin manage" on public.dv_accounting_tax_slips
  for all to authenticated
  using (public.dv_accounting_has_permission('tax_slips.manage'))
  with check (public.dv_accounting_has_permission('tax_slips.manage'));
drop policy if exists "recipients read released tax slips" on public.dv_accounting_tax_slips;
create policy "recipients read released tax slips" on public.dv_accounting_tax_slips
  for select to authenticated
  using (
    status = 'released'
    and (
      recipient_user_id = auth.uid()
      or exists (select 1 from public.dv_accounting_agents a where a.id = agent_id and a.user_id = auth.uid())
      or exists (select 1 from public.dv_accounting_employees e where e.id = employee_id and e.user_id = auth.uid())
    )
  );
grant select, insert, update, delete on public.dv_accounting_tax_slips to authenticated;
