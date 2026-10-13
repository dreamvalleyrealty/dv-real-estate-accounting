

-- 0032: Separate role permissions for Listings and Trade Submissions
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order) values
 ('listings.view','Listings','View listings','Access the Listings workspace.',208),
 ('listings.manage','Listings','Manage listings','Create, edit, approve, and manage listing records and submissions.',209),
 ('trade_submissions.view','Trade Submissions','View trade submissions','Access the Trade Submissions workspace and review queue.',210),
 ('trade_submissions.manage','Trade Submissions','Manage trade submissions','Create, edit, approve, return, and manage trade submissions.',211)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
select r.role,p.code,
 case when r.role='SUPERADMIN' then true
      when r.role in ('ADMIN','MANAGER') and p.code in ('listings.view','listings.manage','trade_submissions.view','trade_submissions.manage') then true
      when r.role in ('STAFF','ACCOUNTANT','VIEWER','AGENT') and p.code in ('listings.view','trade_submissions.view') then true
      else false end,
 'ALL'
from (values ('SUPERADMIN'),('ADMIN'),('MANAGER'),('STAFF'),('ACCOUNTANT'),('VIEWER'),('AGENT')) as r(role)
cross join (values ('listings.view'),('listings.manage'),('trade_submissions.view'),('trade_submissions.manage')) as p(code)
on conflict(role,permission_code) do nothing;
