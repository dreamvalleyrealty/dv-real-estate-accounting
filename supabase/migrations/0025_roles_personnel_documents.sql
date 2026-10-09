-- 0025: roles, permissions, employee/agent headshots and secure personnel documents

alter table public.dv_accounting_agents
  add column if not exists headshot_path text;

alter table public.dv_accounting_employees
  add column if not exists headshot_path text;

create table if not exists public.dv_accounting_user_profiles(
  user_id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references public.dv_accounting_companies(id) on delete cascade,
  display_name text,
  role text not null default 'STAFF'
    check(role in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dv_accounting_role_permissions(
  role text primary key
    check(role in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER')),
  permissions jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.dv_accounting_role_permissions(role,permissions) values
('SUPERADMIN','{"agents":"full","staff":"full","documents":"full","fees":"full","accounting":"full","settings":"full","users":"full"}'),
('ADMIN','{"agents":"full","staff":"full","documents":"full","fees":"full","accounting":"full","settings":"limited","users":"manage"}'),
('MANAGER','{"agents":"edit","staff":"edit","documents":"manage","fees":"view","accounting":"view","settings":"none","users":"none"}'),
('ACCOUNTANT','{"agents":"view","staff":"view","documents":"view","fees":"full","accounting":"full","settings":"view","users":"none"}'),
('STAFF','{"agents":"view","staff":"view","documents":"limited","fees":"none","accounting":"limited","settings":"none","users":"none"}'),
('VIEWER','{"agents":"view","staff":"view","documents":"none","fees":"none","accounting":"view","settings":"none","users":"none"}')
on conflict(role) do nothing;

create or replace function public.dv_accounting_current_user_role()
returns text
language sql stable security definer set search_path=public
as $$
  select coalesce(
    (select role from public.dv_accounting_user_profiles where user_id=auth.uid() and active),
    case
      when coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),'')='superadmin' then 'SUPERADMIN'
      when coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),'')='admin' then 'ADMIN'
      else 'STAFF'
    end
  )
$$;

create or replace function public.dv_accounting_can_manage_personnel()
returns boolean
language sql stable security definer set search_path=public
as $$
 select public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
$$;

insert into public.dv_accounting_user_profiles(user_id,company_id,display_name,role)
select u.id,(select id from public.dv_accounting_companies order by created_at limit 1),
       coalesce(u.raw_user_meta_data->>'full_name',u.email),
       case
         when u.raw_app_meta_data->>'role'='superadmin' then 'SUPERADMIN'
         when u.raw_app_meta_data->>'role'='admin' then 'ADMIN'
         else 'STAFF'
       end
from auth.users u
on conflict(user_id) do nothing;

create table if not exists public.dv_accounting_personnel_documents(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.dv_accounting_companies(id) on delete cascade,
  agent_id uuid references public.dv_accounting_agents(id) on delete cascade,
  employee_id uuid references public.dv_accounting_employees(id) on delete cascade,
  document_type text not null,
  document_name text not null,
  storage_path text not null,
  mime_type text,
  file_size bigint,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check(((agent_id is not null)::int + (employee_id is not null)::int)=1)
);

create index if not exists idx_dv_personnel_docs_agent on public.dv_accounting_personnel_documents(agent_id);
create index if not exists idx_dv_personnel_docs_employee on public.dv_accounting_personnel_documents(employee_id);

alter table public.dv_accounting_user_profiles enable row level security;
alter table public.dv_accounting_role_permissions enable row level security;
alter table public.dv_accounting_personnel_documents enable row level security;

drop policy if exists "user profiles access" on public.dv_accounting_user_profiles;
create policy "user profiles access" on public.dv_accounting_user_profiles
for all to authenticated
using(user_id=auth.uid() or public.dv_accounting_can_manage_personnel())
with check(user_id=auth.uid() or public.dv_accounting_can_manage_personnel());

drop policy if exists "role permissions read" on public.dv_accounting_role_permissions;
create policy "role permissions read" on public.dv_accounting_role_permissions
for select to authenticated using(true);

drop policy if exists "role permissions manage" on public.dv_accounting_role_permissions;
create policy "role permissions manage" on public.dv_accounting_role_permissions
for all to authenticated
using(public.dv_accounting_current_user_role()='SUPERADMIN')
with check(public.dv_accounting_current_user_role()='SUPERADMIN');

drop policy if exists "personnel documents access" on public.dv_accounting_personnel_documents;
create policy "personnel documents access" on public.dv_accounting_personnel_documents
for all to authenticated
using(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'))
with check(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'));

-- Private bucket for personnel files.
insert into storage.buckets(id,name,public)
values('dv-personnel','dv-personnel',false)
on conflict(id) do update set public=false;

drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read" on storage.objects
for select to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT','STAFF'));

drop policy if exists "dv personnel upload" on storage.objects;
create policy "dv personnel upload" on storage.objects
for insert to authenticated
with check(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "dv personnel update" on storage.objects;
create policy "dv personnel update" on storage.objects
for update to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "dv personnel delete" on storage.objects;
create policy "dv personnel delete" on storage.objects
for delete to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN'));
