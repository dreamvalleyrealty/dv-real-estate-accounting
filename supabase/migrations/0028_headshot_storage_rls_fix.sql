-- 0028: repair headshot upload permissions and align storage read/insert policies.
-- A previous migration could seed the first administrator as STAFF if auth metadata
-- was updated after the profile was created. Promote only those stale STAFF profiles
-- whose trusted auth.app_metadata explicitly marks them as admin/superadmin.
update public.dv_accounting_user_profiles p
set role = case lower(coalesce(u.raw_app_meta_data->>'role',''))
  when 'superadmin' then 'SUPERADMIN'
  when 'super_admin' then 'SUPERADMIN'
  when 'admin' then 'ADMIN'
  when 'manager' then 'MANAGER'
  else p.role
end,
updated_at = now()
from auth.users u
where u.id = p.user_id
  and p.active = true
  and p.role = 'STAFF'
  and lower(coalesce(u.raw_app_meta_data->>'role','')) in ('superadmin','super_admin','admin','manager');

create or replace function public.dv_accounting_current_user_role()
returns text
language sql stable security definer set search_path=public
as $$
  select upper(coalesce(
    (select p.role from public.dv_accounting_user_profiles p
      where p.user_id=auth.uid() and p.active=true limit 1),
    case lower(coalesce((select u.raw_app_meta_data->>'role' from auth.users u where u.id=auth.uid()),''))
      when 'superadmin' then 'SUPERADMIN'
      when 'super_admin' then 'SUPERADMIN'
      when 'admin' then 'ADMIN'
      when 'manager' then 'MANAGER'
      when 'accountant' then 'ACCOUNTANT'
      when 'viewer' then 'VIEWER'
      else 'STAFF'
    end
  ))
$$;

update storage.buckets set public=false where id='dv-personnel';

drop policy if exists "dv personnel upload" on storage.objects;
create policy "dv personnel upload" on storage.objects
for insert to authenticated
with check (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
);

-- Supabase Storage returns the newly inserted object metadata during upload,
-- so SELECT must permit the same privileged uploader to see that new object.
drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read" on storage.objects
for select to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

drop policy if exists "dv personnel update" on storage.objects;
create policy "dv personnel update" on storage.objects
for update to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
)
with check (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
);

drop policy if exists "dv personnel delete" on storage.objects;
create policy "dv personnel delete" on storage.objects
for delete to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
);

drop policy if exists "agent headshot personnel update" on public.dv_accounting_agents;
create policy "agent headshot personnel update" on public.dv_accounting_agents
for update to authenticated
using (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "staff headshot personnel update" on public.dv_accounting_employees;
create policy "staff headshot personnel update" on public.dv_accounting_employees
for update to authenticated
using (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'))
with check (public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));
