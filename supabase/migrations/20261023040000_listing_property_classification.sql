ALTER TABLE public.dv_accounting_listing_submissions
  ADD COLUMN IF NOT EXISTS property_classification text;

UPDATE public.dv_accounting_listing_submissions
SET property_classification = CASE
  WHEN upper(coalesce(property_type, '')) = 'COMMERCIAL' THEN 'COMMERCIAL'
  ELSE 'RESIDENTIAL'
END
WHERE property_classification IS NULL
   OR upper(property_classification) NOT IN ('RESIDENTIAL', 'COMMERCIAL');

ALTER TABLE public.dv_accounting_listing_submissions
  ALTER COLUMN property_classification SET DEFAULT 'RESIDENTIAL';

ALTER TABLE public.dv_accounting_listing_submissions
  ALTER COLUMN property_classification SET NOT NULL;

ALTER TABLE public.dv_accounting_listing_submissions
  DROP CONSTRAINT IF EXISTS dv_accounting_listing_submissions_property_classification_check;

ALTER TABLE public.dv_accounting_listing_submissions
  ADD CONSTRAINT dv_accounting_listing_submissions_property_classification_check
  CHECK (upper(property_classification) IN ('RESIDENTIAL', 'COMMERCIAL'));
