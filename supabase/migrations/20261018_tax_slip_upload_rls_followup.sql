-- Follow-up fix for manual T4/T4A PDF upload.
-- Supabase Storage upsert may require SELECT + UPDATE on an existing object.
-- Give authorized tax-slip administrators SELECT access to objects in this private bucket.
DROP POLICY IF EXISTS "Tax slip admins read documents" ON storage.objects;
CREATE POLICY "Tax slip admins read documents" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'dv-tax-slips'
  AND public.dv_accounting_current_user_role() IN ('SUPERADMIN','ADMIN','BROKER_OF_RECORD')
);

-- Ensure the role helper recognizes Broker of Record when supplied in app metadata.
CREATE OR REPLACE FUNCTION public.dv_accounting_current_user_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT upper(coalesce(
    CASE lower(coalesce(auth.jwt()->'app_metadata'->>'role',''))
      WHEN 'superadmin' THEN 'SUPERADMIN'
      WHEN 'super_admin' THEN 'SUPERADMIN'
      WHEN 'admin' THEN 'ADMIN'
      WHEN 'broker_of_record' THEN 'BROKER_OF_RECORD'
      WHEN 'broker-of-record' THEN 'BROKER_OF_RECORD'
      WHEN 'manager' THEN 'MANAGER'
      WHEN 'accountant' THEN 'ACCOUNTANT'
      WHEN 'viewer' THEN 'VIEWER'
      ELSE NULL
    END,
    (SELECT upper(p.role)
       FROM public.dv_accounting_user_profiles p
      WHERE p.user_id=auth.uid()
        AND p.active=true
      LIMIT 1),
    'STAFF'
  ))
$function$;
