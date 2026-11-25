-- Dynamic, auditable permission catalog management.
-- New catalog entries are denied to all roles except Super Admin until explicitly assigned.

ALTER TABLE public.dv_accounting_permission_catalog
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS created_by uuid,
  ADD COLUMN IF NOT EXISTS updated_by uuid;

CREATE INDEX IF NOT EXISTS dv_accounting_permission_catalog_module_active_order_idx
  ON public.dv_accounting_permission_catalog(module, is_active, sort_order);

DROP TRIGGER IF EXISTS dv_accounting_permission_catalog_audit
  ON public.dv_accounting_permission_catalog;
CREATE TRIGGER dv_accounting_permission_catalog_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.dv_accounting_permission_catalog
  FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_capture_audit_log();

-- Add the initial Deal Lifecycle permission set. No non-Super-Admin role is
-- granted access automatically; the brokerage can assign access per role.
INSERT INTO public.dv_accounting_permission_catalog
  (code, module, label, description, sort_order)
VALUES
  ('deals.view', 'Deal Lifecycle', 'View deals', 'View deal records and lifecycle details.', 2000),
  ('deals.create', 'Deal Lifecycle', 'Create deals', 'Create new deal records and drafts.', 2010),
  ('deals.edit', 'Deal Lifecycle', 'Edit deal information', 'Edit permitted deal details before accounting is finalized.', 2020),
  ('deals.assign_agents', 'Deal Lifecycle', 'Assign agents', 'Assign and manage the agents linked to a deal.', 2030),
  ('deals.documents.submit', 'Deal Lifecycle', 'Submit deal documents', 'Submit required documents for a deal.', 2040),
  ('deals.documents.review', 'Deal Lifecycle', 'Review deal documents', 'Review documents submitted for a deal.', 2050),
  ('deals.documents.approve', 'Deal Lifecycle', 'Approve deal documents', 'Approve documents that meet brokerage requirements.', 2060),
  ('deals.documents.return', 'Deal Lifecycle', 'Return documents for correction', 'Return documents to the submitting agent with a review note.', 2070),
  ('deals.conditions.manage', 'Deal Lifecycle', 'Manage deal conditions', 'Record, update and verify deal conditions.', 2080),
  ('deals.status.change', 'Deal Lifecycle', 'Change deal status', 'Move a deal through permitted lifecycle statuses.', 2090),
  ('deals.mark_firm', 'Deal Lifecycle', 'Mark deal firm', 'Confirm that a deal has become firm.', 2100),
  ('deals.terminate', 'Deal Lifecycle', 'Terminate deal', 'Start the termination workflow for a failed or terminated deal.', 2110),
  ('deals.mutual_release.verify', 'Deal Lifecycle', 'Verify mutual release', 'Record and verify the mandatory mutual release for a terminated deal.', 2120),
  ('deals.deposit_refund.initiate', 'Deal Lifecycle', 'Initiate deposit refund', 'Start the deposit refund process when Dream Valley is the listing brokerage.', 2130),
  ('deals.deposit_refund.approve', 'Deal Lifecycle', 'Approve deposit refund', 'Approve a deposit refund before it is completed.', 2140),
  ('deals.deposit_refund.complete', 'Deal Lifecycle', 'Complete deposit refund', 'Record confirmation that the deposit refund has been completed.', 2150),
  ('deals.reopen', 'Deal Lifecycle', 'Reopen deal', 'Reopen an eligible closed or terminated deal with an audit record.', 2160),
  ('deals.audit.view', 'Deal Lifecycle', 'View deal audit history', 'View the status and activity history for a deal.', 2170),
  ('deals.delete', 'Deal Lifecycle', 'Delete eligible draft deals', 'Delete eligible draft deals that have no posted financial activity.', 2180)
ON CONFLICT (code) DO NOTHING;

-- Ensure every role has a rule row for every Deal Lifecycle feature.
-- Existing rule values are preserved. Super Admin receives full access.
INSERT INTO public.dv_accounting_role_permission_rules
  (role, permission_code, allowed, access_scope)
SELECT roles.role, catalog.code, roles.role = 'SUPERADMIN',
       CASE WHEN roles.role = 'SUPERADMIN' THEN 'ALL' ELSE 'OWN' END
FROM (VALUES
  ('SUPERADMIN'), ('ADMIN'), ('MANAGER'), ('STAFF'),
  ('ACCOUNTANT'), ('VIEWER'), ('AGENT')
) AS roles(role)
CROSS JOIN public.dv_accounting_permission_catalog AS catalog
WHERE catalog.module = 'Deal Lifecycle'
ON CONFLICT (role, permission_code) DO NOTHING;

-- Super Admin-only catalog maintenance. The function is exposed through RPC,
-- so execution is explicitly restricted and authorization is checked inside it.
CREATE OR REPLACE FUNCTION public.dv_accounting_upsert_permission_catalog(
  p_code text,
  p_module text,
  p_label text,
  p_description text DEFAULT '',
  p_sort_order integer DEFAULT 0,
  p_is_active boolean DEFAULT true
)
RETURNS public.dv_accounting_permission_catalog
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_code text := lower(trim(coalesce(p_code, '')));
  v_module text := trim(coalesce(p_module, ''));
  v_label text := trim(coalesce(p_label, ''));
  v_result public.dv_accounting_permission_catalog;
BEGIN
  IF auth.uid() IS NULL
     OR public.dv_accounting_current_user_role() <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Only Super Admin can manage the permission catalog';
  END IF;

  IF v_code !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
     OR length(v_code) > 120 THEN
    RAISE EXCEPTION 'Use a valid permission code such as deals.conditions.manage';
  END IF;
  IF v_module = '' OR length(v_module) > 80 THEN
    RAISE EXCEPTION 'Enter a module name (maximum 80 characters)';
  END IF;
  IF v_label = '' OR length(v_label) > 120 THEN
    RAISE EXCEPTION 'Enter a feature name (maximum 120 characters)';
  END IF;
  IF length(coalesce(p_description, '')) > 500 THEN
    RAISE EXCEPTION 'Description cannot exceed 500 characters';
  END IF;
  IF coalesce(p_sort_order, 0) < 0 THEN
    RAISE EXCEPTION 'Display order cannot be negative';
  END IF;

  INSERT INTO public.dv_accounting_permission_catalog
    (code, module, label, description, sort_order, is_active, created_at, updated_at, created_by, updated_by)
  VALUES
    (v_code, v_module, v_label, coalesce(p_description, ''), coalesce(p_sort_order, 0),
     coalesce(p_is_active, true), now(), now(), auth.uid(), auth.uid())
  ON CONFLICT (code) DO UPDATE
  SET module = excluded.module,
      label = excluded.label,
      description = excluded.description,
      sort_order = excluded.sort_order,
      is_active = excluded.is_active,
      updated_at = now(),
      updated_by = auth.uid()
  RETURNING * INTO v_result;

  INSERT INTO public.dv_accounting_role_permission_rules
    (role, permission_code, allowed, access_scope)
  SELECT roles.role, v_result.code, roles.role = 'SUPERADMIN',
         CASE WHEN roles.role = 'SUPERADMIN' THEN 'ALL' ELSE 'OWN' END
  FROM (VALUES
    ('SUPERADMIN'), ('ADMIN'), ('MANAGER'), ('STAFF'),
    ('ACCOUNTANT'), ('VIEWER'), ('AGENT')
  ) AS roles(role)
  ON CONFLICT (role, permission_code) DO NOTHING;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_upsert_permission_catalog(text, text, text, text, integer, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_upsert_permission_catalog(text, text, text, text, integer, boolean)
  TO authenticated;

-- Only active catalog entries are returned as effective permissions.
CREATE OR REPLACE FUNCTION public.dv_accounting_get_my_permissions()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT coalesce(
    jsonb_object_agg(
      catalog.code,
      jsonb_build_object(
        'allowed', coalesce(user_rule.allowed, role_rule.allowed, false),
        'scope', coalesce(user_rule.access_scope, role_rule.access_scope, 'OWN')
      )
    ),
    '{}'::jsonb
  )
  FROM public.dv_accounting_permission_catalog AS catalog
  LEFT JOIN public.dv_accounting_role_permission_rules AS role_rule
    ON role_rule.permission_code = catalog.code
   AND role_rule.role = public.dv_accounting_current_user_role()
  LEFT JOIN public.dv_accounting_user_permission_overrides AS user_rule
    ON user_rule.permission_code = catalog.code
   AND user_rule.user_id = auth.uid()
  WHERE catalog.is_active = true
    AND EXISTS (
      SELECT 1
      FROM public.dv_accounting_user_profiles AS profile
      WHERE profile.user_id = auth.uid()
        AND profile.active = true
    );
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_get_my_permissions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_get_my_permissions() TO authenticated;

-- Prevent role or user assignments to deactivated catalog entries.
CREATE OR REPLACE FUNCTION public.dv_accounting_set_role_permission(
  p_role text,
  p_permission_code text,
  p_allowed boolean,
  p_scope text DEFAULT 'ALL'
)
RETURNS public.dv_accounting_role_permission_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_result public.dv_accounting_role_permission_rules;
BEGIN
  IF auth.uid() IS NULL
     OR public.dv_accounting_current_user_role() NOT IN ('SUPERADMIN', 'ADMIN') THEN
    RAISE EXCEPTION 'You do not have permission to manage role templates';
  END IF;
  IF p_role NOT IN ('SUPERADMIN', 'ADMIN', 'MANAGER', 'STAFF', 'ACCOUNTANT', 'VIEWER', 'AGENT') THEN
    RAISE EXCEPTION 'Invalid role';
  END IF;
  IF p_scope NOT IN ('ALL', 'BRANCH', 'OWN') THEN
    RAISE EXCEPTION 'Invalid access scope';
  END IF;
  IF p_role = 'SUPERADMIN' AND p_allowed = false THEN
    RAISE EXCEPTION 'Super Admin permissions cannot be removed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dv_accounting_permission_catalog
    WHERE code = p_permission_code AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Unknown or inactive permission code: %', p_permission_code;
  END IF;

  INSERT INTO public.dv_accounting_role_permission_rules
    (role, permission_code, allowed, access_scope, updated_at, updated_by)
  VALUES (p_role, p_permission_code, p_allowed, p_scope, now(), auth.uid())
  ON CONFLICT (role, permission_code) DO UPDATE
  SET allowed = excluded.allowed,
      access_scope = excluded.access_scope,
      updated_at = now(),
      updated_by = auth.uid()
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_set_role_permission(text, text, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_set_role_permission(text, text, boolean, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_user_permission(
  p_user_id uuid,
  p_permission_code text,
  p_allowed boolean,
  p_scope text DEFAULT 'ALL'
)
RETURNS public.dv_accounting_user_permission_overrides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_result public.dv_accounting_user_permission_overrides;
BEGIN
  IF auth.uid() IS NULL
     OR public.dv_accounting_current_user_role() NOT IN ('SUPERADMIN', 'ADMIN') THEN
    RAISE EXCEPTION 'You do not have permission to manage user permissions';
  END IF;
  IF p_user_id IS NULL OR p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Choose another user; changing your own overrides is not allowed';
  END IF;
  IF p_scope NOT IN ('ALL', 'BRANCH', 'OWN') THEN
    RAISE EXCEPTION 'Invalid access scope';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.dv_accounting_permission_catalog
    WHERE code = p_permission_code AND is_active = true
  ) THEN
    RAISE EXCEPTION 'Unknown or inactive permission code: %', p_permission_code;
  END IF;

  INSERT INTO public.dv_accounting_user_permission_overrides
    (user_id, permission_code, allowed, access_scope, updated_at, updated_by)
  VALUES (p_user_id, p_permission_code, p_allowed, p_scope, now(), auth.uid())
  ON CONFLICT (user_id, permission_code) DO UPDATE
  SET allowed = excluded.allowed,
      access_scope = excluded.access_scope,
      updated_at = now(),
      updated_by = auth.uid()
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_set_user_permission(uuid, text, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_set_user_permission(uuid, text, boolean, text)
  TO authenticated;
