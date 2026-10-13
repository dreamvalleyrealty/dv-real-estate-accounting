-- Staff compensation visibility is separate from general staff payroll access.
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
values ('staff.salary.view','Staff Payroll','View staff salary and hourly rates','View hourly rates and annual salaries in staff records.',207)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
select r.role,'staff.salary.view',r.role='SUPERADMIN','ALL'
from (values ('SUPERADMIN'),('ADMIN'),('MANAGER'),('STAFF'),('ACCOUNTANT'),('VIEWER')) as r(role)
on conflict(role,permission_code) do nothing;

-- Existing users with explicit overrides retain those choices.
