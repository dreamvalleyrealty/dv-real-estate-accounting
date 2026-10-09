-- 0026: role administration helpers and tighter personnel-document access

alter table public.dv_accounting_user_profiles
  add column if not exists email text;

update public.dv_accounting_user_profiles p
set email=u.email
from auth.users u
where u.id=p.user_id and (p.email is null or p.email='');

create or replace function public.dv_accounting_set_user_role(
  p_user_id uuid,
  p_role text
) returns public.dv_accounting_user_profiles
language plpgsql security definer set search_path=public
as $$
declare r public.dv_accounting_user_profiles;
begin
  if public.dv_accounting_current_user_role()<>'SUPERADMIN' then
    raise exception 'Only Super Admin can change user roles';
  end if;
  if p_role not in ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER') then
    raise exception 'Invalid role';
  end if;
  update public.dv_accounting_user_profiles
  set role=p_role,updated_at=now()
  where user_id=p_user_id
  returning * into r;
  if r.user_id is null then raise exception 'User profile not found'; end if;
  return r;
end $$;

grant execute on function public.dv_accounting_set_user_role(uuid,text) to authenticated;

drop policy if exists "personnel documents access" on public.dv_accounting_personnel_documents;
create policy "personnel documents access" on public.dv_accounting_personnel_documents
for all to authenticated
using(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT'))
with check(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER'));

drop policy if exists "dv personnel read" on storage.objects;
create policy "dv personnel read" on storage.objects
for select to authenticated
using(bucket_id='dv-personnel' and public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT'));

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
