-- 0027: repair personnel storage RLS for existing deployments
-- The headshot upload is a storage.objects INSERT. Make authorization robust
-- against existing users whose role is stored in auth metadata with lower/upper case.

create or replace function public.dv_accounting_current_user_role()
returns text
language sql stable security definer set search_path=public
as $$
  select upper(coalesce(
    (select role from public.dv_accounting_user_profiles
      where user_id=auth.uid() and active limit 1),
    case
      when lower(coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),'')) in ('superadmin','super_admin') then 'SUPERADMIN'
      when lower(coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),''))='admin' then 'ADMIN'
      when lower(coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),''))='manager' then 'MANAGER'
      when lower(coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),''))='accountant' then 'ACCOUNTANT'
      when lower(coalesce((select raw_app_meta_data->>'role' from auth.users where id=auth.uid()),''))='viewer' then 'VIEWER'
      else 'STAFF'
    end
  ))
$$;

-- Keep the personnel bucket private.
update storage.buckets set public=false where id='dv-personnel';

drop policy if exists "dv personnel upload" on storage.objects;
create policy "dv personnel upload" on storage.objects
for insert to authenticated
with check (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER')
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

drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read" on storage.objects
for select to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT')
);

drop policy if exists "dv personnel delete" on storage.objects;
create policy "dv personnel delete" on storage.objects
for delete to authenticated
using (
  bucket_id='dv-personnel'
  and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN')
);

-- Allow the application to update the saved headshot_path after a successful upload.
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
