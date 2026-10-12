ALTER TABLE public.dv_accounting_user_profiles
  ADD COLUMN IF NOT EXISTS phone text;

-- A signed-in user may read their own profile, but may not update role/status columns directly.
DROP POLICY IF EXISTS "user profiles access" ON public.dv_accounting_user_profiles;
CREATE POLICY "user profiles read own or managed"
  ON public.dv_accounting_user_profiles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.dv_accounting_can_manage_personnel());

CREATE POLICY "user profiles managed by other admins"
  ON public.dv_accounting_user_profiles
  FOR ALL TO authenticated
  USING (public.dv_accounting_can_manage_personnel() AND user_id <> auth.uid())
  WITH CHECK (public.dv_accounting_can_manage_personnel() AND user_id <> auth.uid());

REVOKE UPDATE ON public.dv_accounting_user_profiles FROM authenticated;
GRANT UPDATE(display_name, phone) ON public.dv_accounting_user_profiles TO authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM public.dv_accounting_user_profiles p
      WHERE p.user_id = auth.uid() AND p.active = false
    ) THEN 'DISABLED'
    WHEN EXISTS (
      SELECT 1 FROM public.dv_accounting_user_profiles p
      WHERE p.user_id = auth.uid() AND p.active = true
    ) THEN (
      SELECT upper(p.role) FROM public.dv_accounting_user_profiles p
      WHERE p.user_id = auth.uid() AND p.active = true
      LIMIT 1
    )
    ELSE upper(coalesce(
      CASE lower(coalesce(auth.jwt()->'app_metadata'->>'role',''))
        WHEN 'superadmin' THEN 'SUPERADMIN'
        WHEN 'super_admin' THEN 'SUPERADMIN'
        WHEN 'admin' THEN 'ADMIN'
        WHEN 'manager' THEN 'MANAGER'
        WHEN 'accountant' THEN 'ACCOUNTANT'
        WHEN 'viewer' THEN 'VIEWER'
        WHEN 'agent' THEN 'AGENT'
        WHEN 'staff' THEN 'STAFF'
        ELSE NULL
      END,
      'STAFF'
    ))
  END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_update_my_profile(
  p_display_name text,
  p_phone text DEFAULT NULL
)
RETURNS public.dv_accounting_user_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  result public.dv_accounting_user_profiles;
  safe_name text := left(btrim(coalesce(p_display_name,'')),120);
  safe_phone text := left(btrim(coalesce(p_phone,'')),40);
  user_email text := auth.jwt()->>'email';
  fallback_role text := public.dv_accounting_current_user_role();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in to edit your profile'; END IF;
  IF safe_name = '' THEN RAISE EXCEPTION 'Display name is required'; END IF;
  IF fallback_role = 'DISABLED' THEN RAISE EXCEPTION 'This account is disabled'; END IF;

  INSERT INTO public.dv_accounting_user_profiles(user_id,display_name,email,role,active,phone,updated_at)
  VALUES(auth.uid(),safe_name,user_email,fallback_role,true,NULLIF(safe_phone,''),now())
  ON CONFLICT(user_id) DO UPDATE
    SET display_name=excluded.display_name,
        phone=excluded.phone,
        email=coalesce(public.dv_accounting_user_profiles.email,excluded.email),
        updated_at=now()
  RETURNING * INTO result;
  RETURN result;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_user_role(p_user_id uuid, p_role text)
RETURNS public.dv_accounting_user_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r public.dv_accounting_user_profiles;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Only Super Admin can change user roles';
  END IF;
  IF p_user_id IS NULL OR p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Choose another user; changing your own role is not allowed';
  END IF;
  IF upper(p_role) NOT IN ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT') THEN
    RAISE EXCEPTION 'Invalid role';
  END IF;
  UPDATE public.dv_accounting_user_profiles
  SET role=upper(p_role), updated_at=now()
  WHERE user_id=p_user_id
  RETURNING * INTO r;
  IF r.user_id IS NULL THEN RAISE EXCEPTION 'User profile not found'; END IF;

  UPDATE auth.users
  SET raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb)
      || jsonb_build_object('role',lower(upper(p_role)))
  WHERE id=p_user_id;
  RETURN r;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_user_active(p_user_id uuid, p_active boolean)
RETURNS public.dv_accounting_user_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r public.dv_accounting_user_profiles;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Only Super Admin can activate or deactivate user accounts';
  END IF;
  IF p_user_id IS NULL OR p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot deactivate or change your own account status';
  END IF;
  IF p_active IS NULL THEN RAISE EXCEPTION 'Choose an account status'; END IF;
  IF NOT p_active AND EXISTS (
    SELECT 1 FROM public.dv_accounting_user_profiles
    WHERE user_id=p_user_id AND role='SUPERADMIN'
  ) AND (
    SELECT count(*) FROM public.dv_accounting_user_profiles
    WHERE role='SUPERADMIN' AND active=true
  ) <= 1 THEN
    RAISE EXCEPTION 'You cannot deactivate the last active Super Admin';
  END IF;

  UPDATE public.dv_accounting_user_profiles
  SET active=p_active,updated_at=now()
  WHERE user_id=p_user_id
  RETURNING * INTO r;
  IF r.user_id IS NULL THEN RAISE EXCEPTION 'User profile not found'; END IF;
  RETURN r;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_role_permission(
  p_role text, p_permission_code text, p_allowed boolean, p_scope text DEFAULT 'ALL'
)
RETURNS public.dv_accounting_role_permission_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE result public.dv_accounting_role_permission_rules;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND coalesce((public.dv_accounting_get_my_permissions()->'settings.roles.manage'->>'allowed')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage role templates';
  END IF;
  IF upper(p_role) NOT IN ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT') THEN
    RAISE EXCEPTION 'Invalid role';
  END IF;
  IF p_scope NOT IN ('ALL','BRANCH','OWN') THEN RAISE EXCEPTION 'Invalid access scope'; END IF;
  IF upper(p_role)='SUPERADMIN' AND p_allowed=false THEN RAISE EXCEPTION 'Super Admin permissions cannot be removed'; END IF;
  INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at,updated_by)
  VALUES(upper(p_role),p_permission_code,p_allowed,p_scope,now(),auth.uid())
  ON CONFLICT(role,permission_code) DO UPDATE
    SET allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
  RETURNING * INTO result;
  RETURN result;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_user_permission(
  p_user_id uuid, p_permission_code text, p_allowed boolean, p_scope text DEFAULT 'ALL'
)
RETURNS public.dv_accounting_user_permission_overrides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE result public.dv_accounting_user_permission_overrides;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND coalesce((public.dv_accounting_get_my_permissions()->'settings.roles.manage'->>'allowed')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage user permissions';
  END IF;
  IF p_user_id IS NULL OR p_user_id=auth.uid() THEN RAISE EXCEPTION 'Choose another user; changing your own overrides is not allowed'; END IF;
  IF p_scope NOT IN ('ALL','BRANCH','OWN') THEN RAISE EXCEPTION 'Invalid access scope'; END IF;
  IF p_permission_code='settings.roles.manage' AND p_allowed=true AND p_user_id IS NULL THEN RAISE EXCEPTION 'Invalid user'; END IF;
  INSERT INTO public.dv_accounting_user_permission_overrides(user_id,permission_code,allowed,access_scope,updated_at,updated_by)
  VALUES(p_user_id,p_permission_code,p_allowed,p_scope,now(),auth.uid())
  ON CONFLICT(user_id,permission_code) DO UPDATE
    SET allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
  RETURNING * INTO result;
  RETURN result;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_clear_user_permission(p_user_id uuid, p_permission_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND coalesce((public.dv_accounting_get_my_permissions()->'settings.roles.manage'->>'allowed')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage user permissions';
  END IF;
  IF p_user_id IS NULL OR p_user_id=auth.uid() THEN RAISE EXCEPTION 'Choose another user; changing your own overrides is not allowed'; END IF;
  DELETE FROM public.dv_accounting_user_permission_overrides
  WHERE user_id=p_user_id AND permission_code=p_permission_code;
END
$function$;