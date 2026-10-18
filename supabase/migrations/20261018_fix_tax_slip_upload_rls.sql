-- Fix manual T4/T4A PDF uploads for authorized brokerage administrators.
-- The upload screen grants these same roles access, so the database policies
-- must not additionally require a separate tax_slips.manage permission grant.

DROP POLICY IF EXISTS "Tax slip admins upload documents" ON storage.objects;
CREATE POLICY "Tax slip admins upload documents" ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'dv-tax-slips'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
);

DROP POLICY IF EXISTS "Tax slip admins update documents" ON storage.objects;
CREATE POLICY "Tax slip admins update documents" ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'dv-tax-slips'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
)
WITH CHECK (
  bucket_id = 'dv-tax-slips'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
);

DROP POLICY IF EXISTS "Tax slip admins delete documents" ON storage.objects;
CREATE POLICY "Tax slip admins delete documents" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'dv-tax-slips'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
);

DROP POLICY IF EXISTS "tax slips admin manage" ON public.dv_accounting_tax_slips;
CREATE POLICY "tax slips admin manage" ON public.dv_accounting_tax_slips
FOR ALL TO authenticated
USING (
  public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
)
WITH CHECK (
  public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
);
