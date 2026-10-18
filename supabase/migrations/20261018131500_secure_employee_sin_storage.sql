create table if not exists public.dv_accounting_employee_sensitive (
  employee_id uuid primary key references public.dv_accounting_employees(id) on delete cascade,
  company_id uuid not null,
  sin_number text,
  updated_at timestamptz not null default now()
);

alter table public.dv_accounting_employee_sensitive enable row level security;
revoke all on public.dv_accounting_employee_sensitive from anon, authenticated;
grant select, insert, update, delete on public.dv_accounting_employee_sensitive to authenticated;

drop policy if exists employee_sensitive_select on public.dv_accounting_employee_sensitive;
create policy employee_sensitive_select on public.dv_accounting_employee_sensitive
for select to authenticated
using (public.dv_accounting_has_any_permission_all_scope(array['staff.edit','payroll.calculate','payroll.approve']::text[]));

drop policy if exists employee_sensitive_insert on public.dv_accounting_employee_sensitive;
create policy employee_sensitive_insert on public.dv_accounting_employee_sensitive
for insert to authenticated
with check (public.dv_accounting_has_any_permission_all_scope(array['staff.edit','payroll.calculate','payroll.approve']::text[]));

drop policy if exists employee_sensitive_update on public.dv_accounting_employee_sensitive;
create policy employee_sensitive_update on public.dv_accounting_employee_sensitive
for update to authenticated
using (public.dv_accounting_has_any_permission_all_scope(array['staff.edit','payroll.calculate','payroll.approve']::text[]))
with check (public.dv_accounting_has_any_permission_all_scope(array['staff.edit','payroll.calculate','payroll.approve']::text[]));

drop policy if exists employee_sensitive_delete on public.dv_accounting_employee_sensitive;
create policy employee_sensitive_delete on public.dv_accounting_employee_sensitive
for delete to authenticated
using (public.dv_accounting_has_permission_all_scope('staff.edit'));
