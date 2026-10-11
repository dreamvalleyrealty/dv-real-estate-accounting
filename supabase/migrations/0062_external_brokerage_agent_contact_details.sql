-- Add contact and professional membership identifiers to outside brokerage agents.
ALTER TABLE public.dv_accounting_external_brokerage_agents
  ADD COLUMN IF NOT EXISTS agent_phone text,
  ADD COLUMN IF NOT EXISTS reco_number text,
  ADD COLUMN IF NOT EXISTS trreb_membership_number text;
