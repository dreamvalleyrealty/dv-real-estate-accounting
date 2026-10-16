-- Add a dedicated, selectable permission for previewing trade-submission documents.
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
values ('trade_submissions.documents.view','Trade Submissions','View trade documents','Preview and open uploaded trade-submission documents, including closed and paid trades.',205)
on conflict(code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
values
 ('SUPERADMIN','trade_submissions.documents.view',true,'ALL'),
 ('ADMIN','trade_submissions.documents.view',true,'ALL'),
 ('MANAGER','trade_submissions.documents.view',true,'ALL'),
 ('ACCOUNTANT','trade_submissions.documents.view',true,'ALL'),
 ('STAFF','trade_submissions.documents.view',false,'OWN'),
 ('VIEWER','trade_submissions.documents.view',false,'OWN')
on conflict(role,permission_code) do nothing;

create or replace function public.dv_accounting_can_view_trade_documents()
returns boolean
language sql stable security definer set search_path=''
as $$
 select
   coalesce(public.dv_accounting_current_user_role() in ('SUPERADMIN','ADMIN'),false)
   or coalesce((
     select u.allowed
     from public.dv_accounting_user_permission_overrides u
     where u.user_id=auth.uid()
       and u.permission_code='trade_submissions.documents.view'
   ),(
     select r.allowed
     from public.dv_accounting_role_permission_rules r
     where r.role=public.dv_accounting_current_user_role()
       and r.permission_code='trade_submissions.documents.view'
   ),false)
$$;

revoke all on function public.dv_accounting_can_view_trade_documents() from public, anon;
grant execute on function public.dv_accounting_can_view_trade_documents() to authenticated;

drop policy if exists "dv trade documents preview" on storage.objects;
create policy "dv trade documents preview"
on storage.objects for select to authenticated
using (bucket_id='dv-trade-documents' and public.dv_accounting_can_view_trade_documents());
