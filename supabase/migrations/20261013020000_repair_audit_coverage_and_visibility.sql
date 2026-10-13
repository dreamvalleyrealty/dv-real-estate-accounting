-- Repair central audit coverage and allow privileged brokerage roles to review all activity.
-- Existing audit rows are preserved. This migration refreshes the trigger on every public table,
-- including tables added after the original 0062 audit migration.

ALTER TABLE public.dv_accounting_audit_log
  ADD COLUMN IF NOT EXISTS actor_name text;

CREATE OR REPLACE FUNCTION public.dv_accounting_capture_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  v_actor_id := auth.uid();
  v_actor_email := coalesce(auth.jwt()->>'email', auth.jwt()->'user_metadata'->>'email');

  SELECT NULLIF(trim(p.display_name), '')
    INTO v_actor_name
  FROM public.dv_accounting_user_profiles p
  WHERE p.user_id = v_actor_id
  LIMIT 1;

  v_actor_name := coalesce(
    v_actor_name,
    nullif(trim(auth.jwt()->'user_metadata'->>'full_name'), ''),
    nullif(trim(auth.jwt()->'user_metadata'->>'name'), ''),
    nullif(initcap(regexp_replace(split_part(v_actor_email, '@', 1), '[._+-]+', ' ', 'g')), ''),
    CASE WHEN v_actor_id IS NULL THEN 'System / service operation' ELSE 'User' END
  );

  INSERT INTO public.dv_accounting_audit_log
    (table_name, record_id, action, actor_id, actor_email, actor_name, old_data, new_data)
  VALUES (
    TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    CASE WHEN row_data ? 'id' THEN jsonb_build_object('id', row_data->'id') ELSE row_data END,
    TG_OP,
    v_actor_id,
    v_actor_email,
    v_actor_name,
    before_row,
    after_row
  );

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

-- Attach/re-attach the audit trigger to every current public table, including newly introduced tables.
DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename <> 'dv_accounting_audit_log'
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS dv_accounting_audit_trigger ON %I.%I', t.schemaname, t.tablename);
    EXECUTE format(
      'CREATE TRIGGER dv_accounting_audit_trigger AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_capture_audit_log()',
      t.schemaname, t.tablename
    );
  END LOOP;
END;
$$;

ALTER TABLE public.dv_accounting_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dv_accounting_audit_log_read ON public.dv_accounting_audit_log;
CREATE POLICY dv_accounting_audit_log_read ON public.dv_accounting_audit_log
FOR SELECT TO authenticated
USING (
  actor_id = auth.uid()
  OR EXISTS (
    SELECT 1
    FROM public.dv_accounting_user_profiles p
    WHERE p.user_id = auth.uid()
      AND coalesce(p.active, true) = true
      AND upper(replace(coalesce(p.role, ''), '-', '_')) IN
        ('SUPERADMIN', 'SUPER_ADMIN', 'ADMIN', 'BROKER_OF_RECORD', 'BROKER OF RECORD')
  )
  OR upper(replace(coalesce(auth.jwt()->'app_metadata'->>'role', auth.jwt()->'user_metadata'->>'role', ''), '-', '_'))
     IN ('SUPERADMIN', 'SUPER_ADMIN', 'ADMIN', 'BROKER_OF_RECORD', 'BROKER OF RECORD')
);

COMMENT ON TABLE public.dv_accounting_audit_log IS
  'Append-only audit trail for inserts, updates and deletes across current public tables; stores authenticated actor identity and before/after row data.';
