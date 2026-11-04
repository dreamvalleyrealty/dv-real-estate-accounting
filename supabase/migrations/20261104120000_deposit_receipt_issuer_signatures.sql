-- Capture the authenticated issuer and their signature on each listing deposit receipt.
-- Signature images live in a private Storage bucket and remain editable only by their owner.

ALTER TABLE public.dv_accounting_user_profiles
  ADD COLUMN IF NOT EXISTS signature_storage_path text;

ALTER TABLE public.dv_accounting_transaction_trust
  ADD COLUMN IF NOT EXISTS receipt_issued_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS receipt_issued_by_name text,
  ADD COLUMN IF NOT EXISTS receipt_issuer_signature_path text,
  ADD COLUMN IF NOT EXISTS receipt_issued_at timestamptz;

CREATE INDEX IF NOT EXISTS dv_accounting_transaction_trust_issuer_idx
  ON public.dv_accounting_transaction_trust(receipt_issued_by)
  WHERE receipt_issued_by IS NOT NULL;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('dv-user-signatures', 'dv-user-signatures', false, 2097152, ARRAY['image/png','image/jpeg','image/webp'])
ON CONFLICT (id) DO UPDATE
SET public = false, file_size_limit = 2097152,
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
    OR public.dv_accounting_can_manage_personnel()
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

REVOKE UPDATE ON public.dv_accounting_user_profiles FROM authenticated;
GRANT UPDATE(display_name, phone, signature_storage_path)
  ON public.dv_accounting_user_profiles TO authenticated;
