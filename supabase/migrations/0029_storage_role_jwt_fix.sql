-- 0029: make personnel-storage authorization use trusted JWT app_metadata first.
-- This fixes existing deployments where the user profile is stale (for example STAFF)
-- while Supabase Auth app_metadata correctly identifies the user as SUPERADMIN/ADMIN/MANAGER.
-- app_metadata is server-controlled/trusted; user_metadata is intentionally not used for authorization.

create or replace function public.dv_accounting_current_user_role()
returns text
language sql
stable
security definer
set search_path=public
as $$
  select upper(coalesce(
    case lower(coalesce(auth.jwt()->'app_metadata'->>'role',''))
      when 'superadmin' then 'SUPERADMIN'
      when 'super_admin' then 'SUPERADMIN'
      when 'admin' then 'ADMIN'
      when 'manager' then 'MANAGER'
      when 'accountant' then 'ACCOUNTANT'
      when 'viewer' then 'VIEWER'
      else null
    end,
    (select p.role
       from public.dv_accounting_user_profiles p
      where p.user_id=auth.uid()
        and p.active=true
      limit 1),
    'STAFF'
  ))
$$;

-- Keep the bucket private.
update storage.buckets
set public=false
where id='dv-personnel';

-- Recreate the storage policies so they all use the same authoritative role helper.
drop policy if exists "dv personnel upload" on storage.objects;
create policy "dv personnel upload"
on storage.objects
for insert
to authenticated
with check (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
);

drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read"
on storage.objects
for select
to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

drop policy if exists "dv personnel update" on storage.objects;
create policy "dv personnel update"
on storage.objects
for update
to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
)
with check (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
);

drop policy if exists "dv personnel delete" on storage.objects;
create policy "dv personnel delete"
on storage.objects
for delete
to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
);

-- Keep the database headshot-path update aligned with storage upload permissions.
drop policy if exists "agent headshot personnel update" on public.dv_accounting_agents;
create policy "agent headshot personnel update"
on public.dv_accounting_agents
for update
to authenticated
using (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "staff headshot personnel update" on public.dv_accounting_employees;
create policy "staff headshot personnel update"
on public.dv_accounting_employees
for update
to authenticated
using (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));
