create or replace function public.dv_open_house_company_access(p_company_id uuid)
returns boolean
language sql
stable
set search_path to 'public'
as $function$
  select
    exists (
      select 1
      from public.dv_accounting_user_profiles p
      where p.user_id = (select auth.uid())
        and p.active = true
        and (
          p.company_id = p_company_id
          or exists (
            select 1
            from public.dv_accounting_agents a
            where a.company_id = p_company_id
              and (
                a.user_id = (select auth.uid())
                or lower(btrim(coalesce(a.email,''))) = lower(btrim(coalesce(auth.jwt()->>'email','')))
              )
          )
        )
    )
    or (
      public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')
      and exists (select 1 from public.dv_accounting_companies c where c.id = p_company_id)
    );
$function$;
revoke all on function public.dv_open_house_company_access(uuid) from public;
grant execute on function public.dv_open_house_company_access(uuid) to authenticated;

drop policy if exists "open house events company read" on public.dv_open_house_events;
drop policy if exists "open house events create in own company" on public.dv_open_house_events;
drop policy if exists "open house events update own or admin" on public.dv_open_house_events;
drop policy if exists "open house events delete own or admin" on public.dv_open_house_events;
create policy "open house events company read" on public.dv_open_house_events for select to authenticated
using (public.dv_open_house_company_access(company_id));
create policy "open house events create in own company" on public.dv_open_house_events for insert to authenticated
with check (created_by=(select auth.uid()) and public.dv_open_house_company_access(company_id));
create policy "open house events update own or admin" on public.dv_open_house_events for update to authenticated
using (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')))
with check (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')));
create policy "open house events delete own or admin" on public.dv_open_house_events for delete to authenticated
using (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')));

drop policy if exists "open house sign locations company read" on public.dv_open_house_sign_locations;
drop policy if exists "open house sign locations create in own company" on public.dv_open_house_sign_locations;
drop policy if exists "open house sign locations update own or admin" on public.dv_open_house_sign_locations;
drop policy if exists "open house sign locations delete own or admin" on public.dv_open_house_sign_locations;
create policy "open house sign locations company read" on public.dv_open_house_sign_locations for select to authenticated
using (public.dv_open_house_company_access(company_id));
create policy "open house sign locations create in own company" on public.dv_open_house_sign_locations for insert to authenticated
with check (created_by=(select auth.uid()) and public.dv_open_house_company_access(company_id));
create policy "open house sign locations update own or admin" on public.dv_open_house_sign_locations for update to authenticated
using (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')))
with check (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')));
create policy "open house sign locations delete own or admin" on public.dv_open_house_sign_locations for delete to authenticated
using (public.dv_open_house_company_access(company_id) and (created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER')));

drop policy if exists "open house event signs manage own event or admin" on public.dv_open_house_event_signs;
drop policy if exists "open house event signs company read" on public.dv_open_house_event_signs;
create policy "open house event signs company read" on public.dv_open_house_event_signs for select to authenticated
using (public.dv_open_house_company_access(company_id));
create policy "open house event signs manage own event or admin" on public.dv_open_house_event_signs for all to authenticated
using (
 public.dv_open_house_company_access(company_id)
 and exists (
   select 1 from public.dv_open_house_events e
   where e.id=dv_open_house_event_signs.event_id and e.company_id=dv_open_house_event_signs.company_id
     and (e.created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER'))
 )
)
with check (
 public.dv_open_house_company_access(company_id)
 and exists (
   select 1 from public.dv_open_house_events e
   where e.id=dv_open_house_event_signs.event_id and e.company_id=dv_open_house_event_signs.company_id
     and (e.created_by=(select auth.uid()) or public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN','MANAGER','BROKER','BROKER_OF_RECORD','BROKER OF RECORD','OWNER'))
 )
);

drop policy if exists "open house sign photos company read" on storage.objects;
drop policy if exists "open house sign photos company insert" on storage.objects;
drop policy if exists "open house sign photos company update" on storage.objects;
drop policy if exists "open house sign photos company delete" on storage.objects;
create policy "open house sign photos company read" on storage.objects for select to authenticated
using (bucket_id='dv-open-house-sign-photos' and public.dv_open_house_company_access(((storage.foldername(name))[1])::uuid));
create policy "open house sign photos company insert" on storage.objects for insert to authenticated
with check (bucket_id='dv-open-house-sign-photos' and public.dv_open_house_company_access(((storage.foldername(name))[1])::uuid));
create policy "open house sign photos company update" on storage.objects for update to authenticated
using (bucket_id='dv-open-house-sign-photos' and public.dv_open_house_company_access(((storage.foldername(name))[1])::uuid))
with check (bucket_id='dv-open-house-sign-photos' and public.dv_open_house_company_access(((storage.foldername(name))[1])::uuid));
create policy "open house sign photos company delete" on storage.objects for delete to authenticated
using (bucket_id='dv-open-house-sign-photos' and public.dv_open_house_company_access(((storage.foldername(name))[1])::uuid));