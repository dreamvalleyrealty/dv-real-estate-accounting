-- 0030: granular role templates and per-user permission overrides
create table if not exists public.dv_accounting_permission_catalog(
  code text primary key,
  module text not null,
  label text not null,
  description text not null default '',
  sort_order integer not null default 0
);
create table if not exists public.dv_accounting_role_permission_rules(
  role text not null,
  permission_code text not null references public.dv_accounting_permission_catalog(code) on delete cascade,
  allowed boolean not null default false,
  access_scope text not null default 'ALL' check(access_scope in ('ALL','BRANCH','OWN')),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key(role,permission_code)
);
create table if not exists public.dv_accounting_user_permission_overrides(
  user_id uuid not null references auth.users(id) on delete cascade,
  permission_code text not null references public.dv_accounting_permission_catalog(code) on delete cascade,
  allowed boolean not null,
  access_scope text not null default 'ALL' check(access_scope in ('ALL','BRANCH','OWN')),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key(user_id,permission_code)
);
alter table public.dv_accounting_permission_catalog enable row level security;
alter table public.dv_accounting_role_permission_rules enable row level security;
alter table public.dv_accounting_user_permission_overrides enable row level security;
drop policy if exists "permission catalog read" on public.dv_accounting_permission_catalog;
create policy "permission catalog read" on public.dv_accounting_permission_catalog for select to authenticated using(true);
drop policy if exists "role permission rules read" on public.dv_accounting_role_permission_rules;
create policy "role permission rules read" on public.dv_accounting_role_permission_rules for select to authenticated using(true);
drop policy if exists "user permission overrides read" on public.dv_accounting_user_permission_overrides;
create policy "user permission overrides read" on public.dv_accounting_user_permission_overrides for select to authenticated using(user_id=auth.uid() or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN'));
drop policy if exists "user permission overrides manage" on public.dv_accounting_user_permission_overrides;
create policy "user permission overrides manage" on public.dv_accounting_user_permission_overrides for all to authenticated using(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')) with check(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN'));

insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order) values
('dashboard.view','Dashboard','View dashboard','View financial summary cards and operational alerts.',10),
('transactions.view','Transactions','View transactions','View transaction records and deal details.',20),
('transactions.create','Transactions','Create transactions','Create draft transaction records.',21),
('transactions.edit','Transactions','Edit transactions','Edit draft transaction details.',22),
('transactions.finalize','Transactions','Finalize transactions','Post a transaction to the accounting ledger.',23),
('banking.view','Banking','View banking','View bank accounts, feeds and reconciliation data.',30),
('banking.reconcile','Banking','Reconcile accounts','Match bank activity and complete reconciliations.',31),
('expenses.view','Expenses & A/P','View expenses','View expenses, vendors and accounts payable.',40),
('expenses.create','Expenses & A/P','Create expenses','Record new expense entries.',41),
('expenses.edit','Expenses & A/P','Edit expenses','Edit unposted expense details.',42),
('expenses.pay','Expenses & A/P','Pay expenses','Record payments from operating accounts.',43),
('agents.view','Agents','View agents','View agent master records.',50),
('agents.create','Agents','Create agents','Add agent master records.',51),
('agents.edit','Agents','Edit agents','Edit agent details and status.',52),
('agents.import','Agents','Import agent lists','Import agent rows from Excel/CSV or text-based PDF.',53),
('agents.delete','Agents','Delete agents','Delete eligible agent records; historical records may prevent deletion.',54),
('agents.documents.view','Agents','View agent documents','View personnel documents and headshots.',55),
('agents.documents.manage','Agents','Manage agent documents','Upload or remove personnel documents and headshots.',56),
('fees.view','Agent Fees','View fee plans','View agent fee plans, recurring fees and service charges.',60),
('fees.manage','Agent Fees','Manage fee plans','Create and edit fee plans, recurring fees and service charges.',61),
('commission.view','Commission Payroll','View commission payroll','View commission records and cheque history.',70),
('commission.preview','Commission Payroll','Preview commission deductions','Calculate and preview fees before cheque issue.',71),
('commission.issue','Commission Payroll','Issue commission cheques','Issue and record agent commission cheques.',72),
('staff.view','Staff Payroll','View staff','View employee records and staff hours.',80),
('staff.create','Staff Payroll','Create staff','Add employee records.',81),
('staff.edit','Staff Payroll','Edit staff','Edit employee details and compensation setup.',82),
('staff.hours.manage','Staff Payroll','Manage staff hours','Enter and edit staff time entries.',83),
('staff.documents.view','Staff Payroll','View staff documents','View staff personnel documents.',84),
('staff.documents.manage','Staff Payroll','Manage staff documents','Upload and manage staff personnel documents.',85),
('payroll.view','Staff Payroll','View payroll','View payroll runs, pay statements and deductions.',90),
('payroll.calculate','Staff Payroll','Calculate payroll','Calculate payroll and statutory deductions.',91),
('payroll.approve','Staff Payroll','Approve payroll','Approve a calculated payroll run.',92),
('payroll.post','Staff Payroll','Post payroll','Post payroll to the accounting ledger.',93),
('payroll.remit','Staff Payroll','Manage CRA remittances','Manage payroll remittance records.',94),
('tax.view','HST / Tax','View tax','View HST and tax working papers.',100),
('tax.manage','HST / Tax','Manage tax','Edit tax working papers and HST calculations.',101),
('reports.view','Reports','View reports','View financial and operational reports.',110),
('reports.export','Reports','Export reports','Export report data and working papers.',111),
('compliance.view','Compliance','View compliance','View compliance tasks and month-end controls.',120),
('compliance.close','Compliance','Close month end','Mark required controls complete and close periods.',121),
('settings.view','Settings','View settings','View company and application settings.',130),
('settings.company.manage','Settings','Manage company settings','Change brokerage configuration and accounting setup.',131),
('settings.banking.manage','Settings','Manage bank accounts','Add and configure bank accounts.',132),
('settings.users.manage','Settings','Manage users','Change user status and base roles.',133),
('settings.roles.manage','Settings','Manage roles and permissions','Edit role templates and user-specific permission overrides.',134)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

-- Role templates: secure defaults. Per-user overrides can grant or deny individual actions.
insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
select r.role,c.code,
 case
  when r.role='SUPERADMIN' then true
  when r.role='ADMIN' then c.code not in ('settings.roles.manage') or true
  when r.role='MANAGER' then c.code in ('dashboard.view','transactions.view','transactions.create','transactions.edit','banking.view','expenses.view','expenses.create','expenses.edit','agents.view','agents.create','agents.edit','agents.import','agents.documents.view','agents.documents.manage','fees.view','fees.manage','commission.view','commission.preview','commission.issue','staff.view','staff.create','staff.edit','staff.hours.manage','staff.documents.view','reports.view','reports.export','compliance.view','settings.view')
  when r.role='ACCOUNTANT' then c.module in ('Dashboard','Transactions','Banking','Expenses & A/P','Commission Payroll','Staff Payroll','HST / Tax','Reports','Compliance') and c.code not in ('transactions.create','transactions.edit','transactions.finalize','banking.reconcile','expenses.create','expenses.edit','expenses.pay','commission.issue','staff.create','staff.edit','staff.hours.manage','payroll.approve','payroll.post','tax.manage','compliance.close')
  when r.role='STAFF' then c.code in ('dashboard.view','agents.view','staff.view','staff.hours.manage','reports.view')
  else c.code in ('dashboard.view','reports.view')
 end,
 case when r.role='STAFF' then 'OWN' else 'ALL' end
from (values('SUPERADMIN'),('ADMIN'),('MANAGER'),('STAFF'),('ACCOUNTANT'),('VIEWER')) r(role)
cross join public.dv_accounting_permission_catalog c
on conflict(role,permission_code) do nothing;

create or replace function public.dv_accounting_get_my_permissions()
returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_object_agg(c.code,jsonb_build_object(
   'allowed',coalesce(u.allowed,r.allowed,false),
   'scope',coalesce(u.access_scope,r.access_scope,'OWN')
  )), '{}'::jsonb)
 from public.dv_accounting_permission_catalog c
 left join public.dv_accounting_role_permission_rules r
   on r.permission_code=c.code and r.role=public.dv_accounting_current_user_role()
 left join public.dv_accounting_user_permission_overrides u
   on u.permission_code=c.code and u.user_id=auth.uid()
 where exists(select 1 from public.dv_accounting_user_profiles p where p.user_id=auth.uid() and p.active=true)
$$;
revoke all on function public.dv_accounting_get_my_permissions() from public;
grant execute on function public.dv_accounting_get_my_permissions() to authenticated;

create or replace function public.dv_accounting_set_role_permission(p_role text,p_permission_code text,p_allowed boolean,p_scope text default 'ALL')
returns public.dv_accounting_role_permission_rules language plpgsql security definer set search_path=public as $$
declare result public.dv_accounting_role_permission_rules;
begin
 if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN') then raise exception 'You do not have permission to manage role templates'; end if;
 if p_role not in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER') then raise exception 'Invalid role'; end if;
 if p_scope not in ('ALL','BRANCH','OWN') then raise exception 'Invalid access scope'; end if;
 if p_role='SUPERADMIN' and p_allowed=false then raise exception 'Super Admin permissions cannot be removed'; end if;
 insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at,updated_by)
 values(p_role,p_permission_code,p_allowed,p_scope,now(),auth.uid())
 on conflict(role,permission_code) do update set allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
 returning * into result;
 return result;
end $$;
grant execute on function public.dv_accounting_set_role_permission(text,text,boolean,text) to authenticated;

create or replace function public.dv_accounting_set_user_permission(p_user_id uuid,p_permission_code text,p_allowed boolean,p_scope text default 'ALL')
returns public.dv_accounting_user_permission_overrides language plpgsql security definer set search_path=public as $$
declare result public.dv_accounting_user_permission_overrides;
begin
 if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN') then raise exception 'You do not have permission to manage user permissions'; end if;
 if p_user_id is null or p_user_id=auth.uid() then raise exception 'Choose another user; changing your own overrides is not allowed'; end if;
 if p_scope not in ('ALL','BRANCH','OWN') then raise exception 'Invalid access scope'; end if;
 insert into public.dv_accounting_user_permission_overrides(user_id,permission_code,allowed,access_scope,updated_at,updated_by)
 values(p_user_id,p_permission_code,p_allowed,p_scope,now(),auth.uid())
 on conflict(user_id,permission_code) do update set allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
 returning * into result;
 return result;
end $$;
grant execute on function public.dv_accounting_set_user_permission(uuid,text,boolean,text) to authenticated;

create or replace function public.dv_accounting_clear_user_permission(p_user_id uuid,p_permission_code text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if public.dv_accounting_current_user_role() not in ('SUPERADMIN','ADMIN') then raise exception 'You do not have permission to manage user permissions'; end if;
 if p_user_id is null or p_user_id=auth.uid() then raise exception 'Choose another user; changing your own overrides is not allowed'; end if;
 delete from public.dv_accounting_user_permission_overrides where user_id=p_user_id and permission_code=p_permission_code;
end $$;
grant execute on function public.dv_accounting_clear_user_permission(uuid,text) to authenticated;
