-- SUPERADMIN is the unrestricted system administrator. Do not let role rules or per-user
-- overrides remove access from an active SUPERADMIN profile.
update public.dv_accounting_role_permission_rules
set allowed=true, access_scope='ALL', updated_at=now()
where upper(replace(replace(role,'_',''),' ','')) in ('SUPERADMIN','SUPERADMINISTRATOR');

insert into public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at)
select 'SUPERADMIN',c.code,true,'ALL',now()
from public.dv_accounting_permission_catalog c
where not exists(
 select 1 from public.dv_accounting_role_permission_rules r
 where upper(replace(replace(r.role,'_',''),' ','')) in ('SUPERADMIN','SUPERADMINISTRATOR')
 and r.permission_code=c.code
);

create or replace function public.dv_accounting_get_my_permissions()
returns jsonb
language sql
stable
security definer
set search_path=public
as $function$
 select case
  when public.dv_accounting_current_user_role() in ('SUPERADMIN','SUPERADMINISTRATOR')
   and exists(select 1 from public.dv_accounting_user_profiles p where p.user_id=auth.uid() and p.active=true)
  then coalesce((
   select jsonb_object_agg(c.code,jsonb_build_object('allowed',true,'scope','ALL'))
   from public.dv_accounting_permission_catalog c
  ),'{}'::jsonb)
  else coalesce((
   select jsonb_object_agg(c.code,jsonb_build_object(
    'allowed',coalesce(u.allowed,r.allowed,false),
    'scope',coalesce(u.access_scope,r.access_scope,'OWN')
   ))
   from public.dv_accounting_permission_catalog c
   left join public.dv_accounting_role_permission_rules r
    on r.permission_code=c.code and r.role=public.dv_accounting_current_user_role()
   left join public.dv_accounting_user_permission_overrides u
    on u.permission_code=c.code and u.user_id=auth.uid()
   where exists(select 1 from public.dv_accounting_user_profiles p where p.user_id=auth.uid() and p.active=true)
  ),'{}'::jsonb)
 end
$function$;

create or replace function public.dv_accounting_has_permission(p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path=public
as $function$
 select public.dv_accounting_current_user_role() in ('SUPERADMIN','SUPERADMINISTRATOR')
  or coalesce((public.dv_accounting_get_my_permissions()->p_permission_code->>'allowed')::boolean,false)
$function$;

create or replace function public.dv_accounting_has_permission_all_scope(p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path=public
as $function$
 select public.dv_accounting_current_user_role() in ('SUPERADMIN','SUPERADMINISTRATOR')
  or (
   coalesce((public.dv_accounting_get_my_permissions()->p_permission_code->>'allowed')::boolean,false)
   and coalesce(public.dv_accounting_get_my_permissions()->p_permission_code->>'scope','OWN')='ALL'
  )
$function$;
