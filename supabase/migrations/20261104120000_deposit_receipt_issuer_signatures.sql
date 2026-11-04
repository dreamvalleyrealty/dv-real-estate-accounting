-- Private per-user signature storage and immutable deposit receipt issuer snapshots.
ALTER TABLE public.dv_accounting_user_profiles
  ADD COLUMN IF NOT EXISTS signature_storage_path text;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'dv-user-signatures',
  'dv-user-signatures',
  false,
  2097152,
  ARRAY['image/png','image/jpeg','image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = 2097152,
    allowed_mime_types = ARRAY['image/png','image/jpeg','image/webp'];

DROP POLICY IF EXISTS "Users upload own signature" ON storage.objects;
CREATE POLICY "Users upload own signature"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'dv-user-signatures'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users read own signature" ON storage.objects;
CREATE POLICY "Users read own signature"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'dv-user-signatures'
  AND (
    (storage.foldername(name))[1] = auth.uid()::text
    OR public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
  )
);

DROP POLICY IF EXISTS "Users update own signature" ON storage.objects;
CREATE POLICY "Users update own signature"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'dv-user-signatures'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'dv-user-signatures'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users delete own signature" ON storage.objects;
CREATE POLICY "Users delete own signature"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'dv-user-signatures'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Users can only change their own signature pointer through this narrow RPC.
CREATE OR REPLACE FUNCTION public.dv_accounting_update_my_profile_signature(
  p_signature_storage_path text
)
RETURNS public.dv_accounting_user_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  result public.dv_accounting_user_profiles;
  safe_path text := nullif(btrim(coalesce(p_signature_storage_path,'')), '');
  fallback_role text := public.dv_accounting_current_user_role();
  user_email text := auth.jwt()->>'email';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to update your signature';
  END IF;
  IF fallback_role = 'DISABLED' THEN
    RAISE EXCEPTION 'This account is disabled';
  END IF;
  IF safe_path IS NOT NULL AND (
    safe_path !~ ('^' || auth.uid()::text || '/[A-Za-z0-9._/-]+$')
    OR position('..' in safe_path) > 0
  ) THEN
    RAISE EXCEPTION 'Signature path must be inside your own private signature folder';
  END IF;

  INSERT INTO public.dv_accounting_user_profiles(
    user_id, display_name, email, role, active, signature_storage_path, updated_at
  )
  VALUES (
    auth.uid(),
    coalesce(nullif(btrim(auth.jwt()->'user_metadata'->>'display_name'), ''),
             nullif(btrim(auth.jwt()->'user_metadata'->>'full_name'), ''),
             nullif(split_part(coalesce(user_email,''),'@',1), ''),
             'User'),
    user_email,
    fallback_role,
    true,
    safe_path,
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
    SET signature_storage_path = excluded.signature_storage_path,
        updated_at = now()
  RETURNING * INTO result;

  RETURN result;
END
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_update_my_profile_signature(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_update_my_profile_signature(text) TO authenticated;

-- A separate immutable issuance record is required because one transaction can
-- receive multiple deposits and each printed receipt needs its own issuer snapshot.
CREATE TABLE IF NOT EXISTS public.dv_accounting_deposit_receipt_issuances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trust_transaction_id uuid NOT NULL UNIQUE
    REFERENCES public.dv_accounting_trust_transactions(id) ON DELETE CASCADE,
  transaction_id uuid NOT NULL
    REFERENCES public.dv_accounting_transactions(id) ON DELETE CASCADE,
  issued_by uuid NOT NULL REFERENCES auth.users(id),
  issuer_name text NOT NULL CHECK (length(btrim(issuer_name)) > 0),
  issuer_signature_path text,
  issued_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dv_accounting_deposit_receipt_issuances_transaction_idx
  ON public.dv_accounting_deposit_receipt_issuances(transaction_id, issued_at DESC);

ALTER TABLE public.dv_accounting_deposit_receipt_issuances ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON public.dv_accounting_deposit_receipt_issuances TO authenticated;

DROP POLICY IF EXISTS "Admins read deposit receipt issuances" ON public.dv_accounting_deposit_receipt_issuances;
CREATE POLICY "Admins read deposit receipt issuances"
ON public.dv_accounting_deposit_receipt_issuances
FOR SELECT TO authenticated
USING (
  public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
);

DROP POLICY IF EXISTS "Admins issue deposit receipts as themselves" ON public.dv_accounting_deposit_receipt_issuances;
CREATE POLICY "Admins issue deposit receipts as themselves"
ON public.dv_accounting_deposit_receipt_issuances
FOR INSERT TO authenticated
WITH CHECK (
  issued_by = auth.uid()
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
  AND (
    issuer_signature_path IS NULL
    OR issuer_signature_path ~ ('^' || auth.uid()::text || '/[A-Za-z0-9._/-]+$')
  )
);
