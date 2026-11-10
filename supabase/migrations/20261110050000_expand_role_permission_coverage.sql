-- Expand permission coverage without changing any existing grants or user overrides.
-- New settings capabilities default to denied for every non-Super-Admin role.
INSERT INTO public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
VALUES
 ('settings.documents.manage','Settings','Manage document requirements','Configure trade, listing, transaction and agent document requirements.',135),
 ('settings.security.manage','Settings','Manage login security','View and manage active user login sessions.',136),
 ('settings.audit.view','Settings','View audit history','View administrative and financial audit logs.',137),
 ('settings.notifications.manage','Settings','Manage notifications','Configure SMS notification settings and templates.',138)
ON CONFLICT(code) DO NOTHING;

-- Make the permission matrix complete. Missing rows already resolve to denied/OWN;
-- inserting those same values makes the current effective access explicit without
-- changing any existing allowed flags, scopes, or individual user overrides.
INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
SELECT r.role,c.code,false,'OWN'
FROM (VALUES('SUPERADMIN'),('ADMIN'),('MANAGER'),('STAFF'),('ACCOUNTANT'),('VIEWER'),('AGENT')) AS r(role)
CROSS JOIN public.dv_accounting_permission_catalog c
ON CONFLICT(role,permission_code) DO NOTHING;

-- AGENT already exists in the role-permission table and is selectable in the UI.
-- Permit administrators to edit its template; preserve all current template values.
CREATE OR REPLACE FUNCTION public.dv_accounting_set_role_permission(
 p_role text,p_permission_code text,p_allowed boolean,p_scope text DEFAULT 'ALL'
) RETURNS public.dv_accounting_role_permission_rules
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result public.dv_accounting_role_permission_rules;
BEGIN
 IF public.dv_accounting_current_user_role() NOT IN ('SUPERADMIN','ADMIN') THEN
   RAISE EXCEPTION 'You do not have permission to manage role templates';
 END IF;
 IF p_role NOT IN ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT') THEN
   RAISE EXCEPTION 'Invalid role';
 END IF;
 IF p_scope NOT IN ('ALL','BRANCH','OWN') THEN
   RAISE EXCEPTION 'Invalid access scope';
 END IF;
 IF p_role='SUPERADMIN' AND p_allowed=false THEN
   RAISE EXCEPTION 'Super Admin permissions cannot be removed';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.dv_accounting_permission_catalog WHERE code=p_permission_code) THEN
   RAISE EXCEPTION 'Unknown permission code: %',p_permission_code;
 END IF;
 INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at,updated_by)
 VALUES(p_role,p_permission_code,p_allowed,p_scope,now(),auth.uid())
 ON CONFLICT(role,permission_code) DO UPDATE
 SET allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
 RETURNING * INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.dv_accounting_set_role_permission(text,text,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_set_role_permission(text,text,boolean,text) TO authenticated;
