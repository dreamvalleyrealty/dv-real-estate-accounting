alter table public.dv_accounting_employees
  add column if not exists employee_number text,
  add column if not exists address text,
  add column if not exists sin_number text;

create sequence if not exists public.dv_accounting_employee_number_seq;

do $$
declare next_value bigint;
begin
  select greatest(
    coalesce(max(nullif(regexp_replace(employee_number, '[^0-9]', '', 'g'), '')::bigint), 0) + 1,
    1
  ) into next_value
  from public.dv_accounting_employees
  where employee_number is not null;
  perform setval('public.dv_accounting_employee_number_seq', next_value, false);
end $$;

create or replace function public.dv_accounting_assign_employee_number()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.employee_number is null or btrim(new.employee_number) = '' then
    new.employee_number := 'EMP-' || lpad(nextval('public.dv_accounting_employee_number_seq')::text, 5, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists dv_accounting_employees_assign_number on public.dv_accounting_employees;
create trigger dv_accounting_employees_assign_number
before insert on public.dv_accounting_employees
for each row execute function public.dv_accounting_assign_employee_number();

update public.dv_accounting_employees
set employee_number = 'EMP-' || lpad(nextval('public.dv_accounting_employee_number_seq')::text, 5, '0')
where employee_number is null or btrim(employee_number) = '';

create unique index if not exists dv_accounting_employees_employee_number_uidx
on public.dv_accounting_employees(employee_number);

comment on column public.dv_accounting_employees.sin_number is
'Highly sensitive Canadian SIN. Restrict access using employee-table RLS and never expose in general employee lists or logs.';
