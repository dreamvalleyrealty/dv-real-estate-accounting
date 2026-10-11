-- Add Social Insurance Number to agent profiles.
-- SIN is sensitive personal information: ensure access to dv_accounting_agents
-- is limited by your Supabase RLS policies to authorized brokerage personnel.
ALTER TABLE public.dv_accounting_agents
  ADD COLUMN IF NOT EXISTS sin_number text;
