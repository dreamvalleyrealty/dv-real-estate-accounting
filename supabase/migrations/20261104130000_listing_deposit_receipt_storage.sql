-- Allow brokerage admins to upload, preview and replace supporting documents
-- for listing deposit receipts in the existing private trade-document bucket.

UPDATE storage.buckets
SET allowed_mime_types = ARRAY[
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/tiff',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
]
WHERE id = 'dv-trade-documents';

DROP POLICY IF EXISTS "listing deposit receipt admin upload" ON storage.objects;
CREATE POLICY "listing deposit receipt admin upload"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = 'listings'
  AND (storage.foldername(name))[3] = 'listing-deposit-receipts'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
);

DROP POLICY IF EXISTS "listing deposit receipt admin read" ON storage.objects;
CREATE POLICY "listing deposit receipt admin read"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = 'listings'
  AND (storage.foldername(name))[3] = 'listing-deposit-receipts'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
);

DROP POLICY IF EXISTS "listing deposit receipt admin delete" ON storage.objects;
CREATE POLICY "listing deposit receipt admin delete"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = 'listings'
  AND (storage.foldername(name))[3] = 'listing-deposit-receipts'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','MANAGER')
);
