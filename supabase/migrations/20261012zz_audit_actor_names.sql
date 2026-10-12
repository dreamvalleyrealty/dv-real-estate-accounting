-- Store a human-readable actor name in the audit trail while retaining actor_id/email for traceability.
ALTER TABLE public.dv_accounting_audit_log
  ADD COLUMN IF NOT EXISTS actor_name text;

-- Backfill names for existing audit records from application profiles and auth metadata.
UPDATE public.dv_accounting_audit_log l
SET actor_name = COALESCE(
  NULLIF(trim(p.display_name), ''),
  NULLIF(trim(u.raw_user_meta_data->>'full_name'), ''),
  NULLIF(trim(u.raw_user_meta_data->>'name'), ''),
  NULLIF(initcap(regexp_replace(split_part(l.actor_email, '@', 1), '[._+-]+', ' ', 'g')), '')
)
FROM auth.users u
LEFT JOIN public.dv_accounting_user_profiles p ON p.user_id = u.id
WHERE l.actor_id = u.id
  AND (l.actor_name IS NULL OR trim(l.actor_name) = '');

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
    CASE WHEN v_actor_id IS NULL THEN 'System' ELSE 'User' END
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

COMMENT ON COLUMN public.dv_accounting_audit_log.actor_name IS
  'Human-readable name of the user who performed the change; actor_id and actor_email remain available for traceability.';
