ALTER TABLE public.dv_accounting_external_brokerage_agents
  ADD COLUMN IF NOT EXISTS agent_phone text;

-- Populate existing brokerage-agent phone numbers from matching master contacts.
UPDATE public.dv_accounting_external_brokerage_agents AS a
SET agent_phone = c.phone,
    updated_at = now()
FROM public.dv_accounting_external_brokerages AS b,
     public.dv_accounting_contacts AS c
WHERE a.brokerage_id = b.id
  AND lower(trim(c.company_name)) = lower(trim(coalesce(b.company_name, b.brokerage_name)))
  AND lower(trim(concat_ws(' ', c.first_name, c.last_name))) = lower(trim(a.agent_name))
  AND upper(coalesce(c.contact_type, '')) = 'AGENT'
  AND nullif(trim(c.phone), '') IS NOT NULL
  AND nullif(trim(a.agent_phone), '') IS NULL;
