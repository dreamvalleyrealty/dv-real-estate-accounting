alter table public.dv_open_house_event_signs add column if not exists photo_path text;
drop policy if exists "open house event signs company read" on public.dv_open_house_event_signs;
create policy "open house event signs company read" on public.dv_open_house_event_signs
for select to authenticated using (
 exists(select 1 from public.dv_accounting_user_profiles p where p.user_id=(select auth.uid()) and p.active=true and p.company_id=dv_open_house_event_signs.company_id)
);