-- Correct listing-document storage policies to resolve the listing id from
-- the listing folder (listings/<listing-id>/<user-id>/<file>).
DROP POLICY IF EXISTS "listing storage agent insert" ON storage.objects;
CREATE POLICY "listing storage agent insert"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = 'listings'
  AND EXISTS (
    SELECT 1 FROM public.dv_accounting_listing_submissions s
    JOIN public.dv_accounting_agents a ON a.id = s.agent_id
    WHERE s.id = ((storage.foldername(name))[2])::uuid
      AND s.status IN ('DRAFT', 'NEEDS_CHANGES')
      AND lower(trim(a.email)) = lower(trim(coalesce(auth.jwt()->>'email', '')))
  )
);
DROP POLICY IF EXISTS "listing storage agent read" ON storage.objects;
CREATE POLICY "listing storage agent read"
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'dv-trade-documents'
  AND (storage.foldername(name))[1] = 'listings'
  AND EXISTS (
    SELECT 1 FROM public.dv_accounting_listing_submissions s
    JOIN public.dv_accounting_agents a ON a.id = s.agent_id
    WHERE s.id = ((storage.foldername(name))[2])::uuid
      AND lower(trim(a.email)) = lower(trim(coalesce(auth.jwt()->>'email', '')))
  )
);
