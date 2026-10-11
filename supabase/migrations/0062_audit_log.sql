-- Central audit trail for database changes across the public schema.
CREATE TABLE IF NOT EXISTS public.dv_accounting_audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  table_name text NOT NULL,
  record_id jsonb,
  action text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  actor_id uuid,
  actor_email text,
  changed_at timestamptz NOT NULL DEFAULT now(),
  old_data jsonb,
  new_data jsonb
);

ALTER TABLE public.dv_accounting_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dv_accounting_audit_log_read ON public.dv_accounting_audit_log;
CREATE POLICY dv_accounting_audit_log_read ON public.dv_accounting_audit_log
  FOR SELECT TO authenticated
  USING (
    actor_id = auth.uid() OR
    upper(coalesce(auth.jwt()->'app_metadata'->>'role', auth.jwt()->'user_metadata'->>'role', '')) IN ('ADMIN','SUPER_ADMIN','BROKER_OF_RECORD')
  );

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

  INSERT INTO public.dv_accounting_audit_log
    (table_name, record_id, action, actor_id, actor_email, old_data, new_data)
  VALUES (
    TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    CASE WHEN row_data ? 'id' THEN jsonb_build_object('id', row_data->'id') ELSE row_data END,
    TG_OP,
    auth.uid(),
    coalesce(auth.jwt()->>'email', auth.jwt()->'user_metadata'->>'email'),
    before_row,
    after_row
  );

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

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

COMMENT ON TABLE public.dv_accounting_audit_log IS 'Append-only audit trail for inserts, updates and deletes across public tables; captures authenticated actor and before/after row data.';
