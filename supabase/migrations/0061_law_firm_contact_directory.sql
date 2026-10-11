-- 0061: law firm directory with movable lawyer/solicitor contacts
CREATE TABLE IF NOT EXISTS public.dv_accounting_law_firms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  firm_name text NOT NULL,
  phone text,
  fax text,
  address text,
  unit text,
  city text,
  province text DEFAULT 'ON',
  postal_code text,
  billing_email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (firm_name)
);

ALTER TABLE public.dv_accounting_contacts
  ADD COLUMN IF NOT EXISTS law_firm_id uuid REFERENCES public.dv_accounting_law_firms(id) ON DELETE SET NULL;

ALTER TABLE public.dv_accounting_law_firms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "authenticated access" ON public.dv_accounting_law_firms;
CREATE POLICY "authenticated access"
  ON public.dv_accounting_law_firms FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS dv_law_firm_name_idx
  ON public.dv_accounting_law_firms(lower(firm_name));

CREATE INDEX IF NOT EXISTS dv_contacts_law_firm_idx
  ON public.dv_accounting_contacts(law_firm_id);

-- Backfill firms from existing lawyer/solicitor contacts, then associate those contacts.
INSERT INTO public.dv_accounting_law_firms (firm_name)
SELECT DISTINCT trim(company_name)
FROM public.dv_accounting_contacts
WHERE NULLIF(trim(company_name), '') IS NOT NULL
  AND upper(coalesce(contact_type,'')) IN ('LAWYER','SOLICITOR','BUYER_SOLICITOR','SELLER_SOLICITOR')
ON CONFLICT (firm_name) DO NOTHING;

UPDATE public.dv_accounting_contacts c
SET law_firm_id = f.id
FROM public.dv_accounting_law_firms f
WHERE c.law_firm_id IS NULL
  AND NULLIF(trim(c.company_name), '') IS NOT NULL
  AND upper(coalesce(c.contact_type,'')) IN ('LAWYER','SOLICITOR','BUYER_SOLICITOR','SELLER_SOLICITOR')
  AND lower(trim(c.company_name)) = lower(trim(f.firm_name));

NOTIFY pgrst, 'reload schema';