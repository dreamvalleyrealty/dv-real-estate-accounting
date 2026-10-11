-- 0060: outside brokerage master agents and brokerage-name compatibility
-- Keep the brokerage master directory usable by existing databases that may already
-- contain a brokerage_name column with a NOT NULL constraint.
ALTER TABLE public.dv_accounting_external_brokerages
  ADD COLUMN IF NOT EXISTS brokerage_name text;

UPDATE public.dv_accounting_external_brokerages
SET brokerage_name = company_name
WHERE NULLIF(trim(brokerage_name), '') IS NULL;

ALTER TABLE public.dv_accounting_external_brokerages
  ALTER COLUMN brokerage_name SET DEFAULT '';

UPDATE public.dv_accounting_external_brokerages
SET brokerage_name = ''
WHERE brokerage_name IS NULL;

ALTER TABLE public.dv_accounting_external_brokerages
  ALTER COLUMN brokerage_name SET NOT NULL;

CREATE TABLE IF NOT EXISTS public.dv_accounting_external_brokerage_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brokerage_id uuid NOT NULL REFERENCES public.dv_accounting_external_brokerages(id) ON DELETE CASCADE,
  agent_name text NOT NULL,
  agent_email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (brokerage_id, agent_name)
);

ALTER TABLE public.dv_accounting_external_brokerage_agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated access" ON public.dv_accounting_external_brokerage_agents;
CREATE POLICY "authenticated access"
  ON public.dv_accounting_external_brokerage_agents
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE INDEX IF NOT EXISTS dv_ext_broker_agents_brokerage_idx
  ON public.dv_accounting_external_brokerage_agents(brokerage_id);

CREATE INDEX IF NOT EXISTS dv_ext_broker_agents_name_idx
  ON public.dv_accounting_external_brokerage_agents(lower(agent_name));

NOTIFY pgrst, 'reload schema';