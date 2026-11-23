-- Protect agent direct-deposit details at the table, storage, and audit layers.
-- Existing permission policies are retained: settings.banking.manage controls changes,
-- while commission.issue permits viewing bank coordinates for commission payment.

DROP POLICY IF EXISTS "authenticated access"
ON public.dv_accounting_agent_bank_details;

REVOKE ALL ON TABLE public.dv_accounting_agent_bank_details FROM anon;

-- The legacy audit policy exposed each actor's own full before/after snapshot and
-- trusted user-editable user_metadata as an admin fallback. Keep the permission-based
-- audit policy below as the sole authenticated read path.
DROP POLICY IF EXISTS dv_accounting_audit_log_read
ON public.dv_accounting_audit_log;

-- Direct-deposit proof files share the personnel bucket with ordinary personnel
-- documents. Restrict this subfolder to bank managers and the owning agent.
DROP POLICY IF EXISTS "dv personnel read" ON storage.objects;
CREATE POLICY "dv personnel read"
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'dv-personnel'
  AND (
    (
      position('/direct-deposit/' IN name) = 0
      AND (
        public.dv_accounting_current_user_role() = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER','ACCOUNTANT'])
        OR public.dv_accounting_has_permission_all_scope('agents.documents.view')
        OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
      )
    )
    OR
    (
      position('/direct-deposit/' IN name) > 0
      AND (
        public.dv_accounting_has_permission_all_scope('settings.banking.manage')
        OR split_part(name, '/', 3) = public.dv_accounting_current_agent_id()::text
      )
    )
  )
);

DROP POLICY IF EXISTS "dv personnel upload" ON storage.objects;
CREATE POLICY "dv personnel upload"
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'dv-personnel'
  AND (
    (
      position('/direct-deposit/' IN name) > 0
      AND public.dv_accounting_has_permission_all_scope('settings.banking.manage')
    )
    OR
    (
      position('/direct-deposit/' IN name) = 0
      AND (
        public.dv_accounting_current_user_role() = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER'])
        OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
      )
    )
  )
);

DROP POLICY IF EXISTS "dv personnel update" ON storage.objects;
CREATE POLICY "dv personnel update"
ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'dv-personnel'
  AND (
    (
      position('/direct-deposit/' IN name) > 0
      AND public.dv_accounting_has_permission_all_scope('settings.banking.manage')
    )
    OR
    (
      position('/direct-deposit/' IN name) = 0
      AND (
        public.dv_accounting_current_user_role() = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER'])
        OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
      )
    )
  )
)
WITH CHECK (
  bucket_id = 'dv-personnel'
  AND (
    (
      position('/direct-deposit/' IN name) > 0
      AND public.dv_accounting_has_permission_all_scope('settings.banking.manage')
    )
    OR
    (
      position('/direct-deposit/' IN name) = 0
      AND (
        public.dv_accounting_current_user_role() = ANY (ARRAY['SUPERADMIN','ADMIN','MANAGER'])
        OR public.dv_accounting_has_permission_all_scope('agents.documents.manage')
      )
    )
  )
);

-- Never copy bank account or routing numbers into new audit snapshots.
CREATE OR REPLACE FUNCTION public.dv_accounting_capture_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  before_row jsonb;
  after_row jsonb;
  row_data jsonb;
  v_actor_id uuid;
  v_actor_email text;
  v_actor_name text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    before_row := NULL;
    after_row := to_jsonb(NEW);
    row_data := after_row;
  ELSIF TG_OP = 'UPDATE' THEN
    before_row := to_jsonb(OLD);
    after_row := to_jsonb(NEW);
    row_data := after_row;
  ELSE
    before_row := to_jsonb(OLD);
    after_row := NULL;
    row_data := before_row;
  END IF;

  IF TG_TABLE_SCHEMA = 'public' AND TG_TABLE_NAME = 'dv_accounting_agent_bank_details' THEN
    before_row := before_row - ARRAY['account_number','institution_number','transit_number','account_name','proof_storage_path','proof_file_name'];
    after_row := after_row - ARRAY['account_number','institution_number','transit_number','account_name','proof_storage_path','proof_file_name'];
    row_data := COALESCE(after_row, before_row);
  END IF;

  v_actor_id := auth.uid();
  v_actor_email := coalesce(auth.jwt()->>'email', auth.jwt()->'user_metadata'->>'email');
  SELECT NULLIF(trim(p.display_name), '') INTO v_actor_name
    FROM public.dv_accounting_user_profiles p WHERE p.user_id = v_actor_id LIMIT 1;
  v_actor_name := coalesce(v_actor_name, nullif(trim(auth.jwt()->'user_metadata'->>'full_name'), ''),
    nullif(trim(auth.jwt()->'user_metadata'->>'name'), ''),
    nullif(initcap(regexp_replace(split_part(v_actor_email, '@', 1), '[._+-]+', ' ', 'g')), ''),
    CASE WHEN v_actor_id IS NULL THEN 'System / service operation' ELSE 'User' END);

  INSERT INTO public.dv_accounting_audit_log
    (table_name, record_id, action, actor_id, actor_email, actor_name, old_data, new_data)
  VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    CASE WHEN row_data ? 'id' THEN jsonb_build_object('id', row_data->'id') ELSE row_data END,
    TG_OP, v_actor_id, v_actor_email, v_actor_name, before_row, after_row);

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$function$;
