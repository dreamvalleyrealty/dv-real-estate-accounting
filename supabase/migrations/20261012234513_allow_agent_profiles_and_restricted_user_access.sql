ALTER TABLE public.dv_accounting_user_profiles
  DROP CONSTRAINT IF EXISTS dv_accounting_user_profiles_role_check;
ALTER TABLE public.dv_accounting_user_profiles
  ADD CONSTRAINT dv_accounting_user_profiles_role_check
  CHECK (role = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT']));

ALTER TABLE public.dv_accounting_role_permissions
  DROP CONSTRAINT IF EXISTS dv_accounting_role_permissions_role_check;
ALTER TABLE public.dv_accounting_role_permissions
  ADD CONSTRAINT dv_accounting_role_permissions_role_check
  CHECK (role = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT']));

CREATE OR REPLACE FUNCTION public.dv_accounting_can_manage_user_access()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN')
    OR coalesce((public.dv_accounting_get_my_permissions()->'settings.roles.manage'->>'allowed')::boolean,false)
    OR coalesce((public.dv_accounting_get_my_permissions()->'settings.users.manage'->>'allowed')::boolean,false)
$function$;

DROP POLICY IF EXISTS "user profiles read own or managed" ON public.dv_accounting_user_profiles;
CREATE POLICY "user profiles read own or managed"
  ON public.dv_accounting_user_profiles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.dv_accounting_can_manage_user_access());
