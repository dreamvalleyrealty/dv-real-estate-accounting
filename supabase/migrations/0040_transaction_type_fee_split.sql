-- 0040: correct brokerage/agent split defaults by transaction type
-- Buy/Sell: brokerage retains 15%, agent receives 85%.
-- Lease: no brokerage percentage is taken, so agent receives 100%.
-- Fixed admin, lead, desk and recurring fees remain separately configurable.

ALTER TABLE public.dv_accounting_fee_plans
  ADD COLUMN IF NOT EXISTS commission_split_buy_sell_percent numeric(7,4) NOT NULL DEFAULT 85,
  ADD COLUMN IF NOT EXISTS commission_split_lease_percent numeric(7,4) NOT NULL DEFAULT 100;

ALTER TABLE public.dv_accounting_agent_fee_settings
  ADD COLUMN IF NOT EXISTS commission_split_buy_sell_override_percent numeric(7,4),
  ADD COLUMN IF NOT EXISTS commission_split_lease_override_percent numeric(7,4);

ALTER TABLE public.dv_accounting_agent_fee_rules
  ADD COLUMN IF NOT EXISTS commission_split_buy_sell_percent numeric(7,4),
  ADD COLUMN IF NOT EXISTS commission_split_lease_percent numeric(7,4);

-- Correct legacy 90% defaults while preserving any non-standard custom values.
UPDATE public.dv_accounting_fee_plans
SET commission_split_percent = 85
WHERE commission_split_percent = 90;

UPDATE public.dv_accounting_fee_plans
SET commission_split_buy_sell_percent =
      CASE WHEN commission_split_buy_sell_percent IS NULL OR commission_split_buy_sell_percent = 90
           THEN 85 ELSE commission_split_buy_sell_percent END,
    commission_split_lease_percent =
      CASE WHEN commission_split_lease_percent IS NULL OR commission_split_lease_percent = 90
           THEN 100 ELSE commission_split_lease_percent END;

UPDATE public.dv_accounting_agent_fee_settings
SET commission_split_override_percent = 85,
    commission_split_buy_sell_override_percent = 85
WHERE commission_split_override_percent = 90;

UPDATE public.dv_accounting_agent_fee_settings
SET commission_split_buy_sell_override_percent = commission_split_override_percent
WHERE commission_split_override_percent IS NOT NULL
  AND commission_split_buy_sell_override_percent IS NULL;

UPDATE public.dv_accounting_agent_fee_rules
SET commission_split_percent = 85
WHERE commission_split_percent = 90;

UPDATE public.dv_accounting_agent_fee_rules
SET commission_split_buy_sell_percent =
      CASE WHEN commission_split_buy_sell_percent IS NULL OR commission_split_buy_sell_percent = 90
           THEN COALESCE(commission_split_percent,85) ELSE commission_split_buy_sell_percent END,
    commission_split_lease_percent =
      CASE WHEN commission_split_lease_percent IS NULL OR commission_split_lease_percent = 90
           THEN 100 ELSE commission_split_lease_percent END;

CREATE OR REPLACE FUNCTION public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 85;
  desk_fee numeric := 0;
  admin_type text := 'AMOUNT';
  admin_value numeric := 0;
  lead_type text := 'AMOUNT';
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  SELECT * INTO fs FROM public.dv_accounting_agent_fee_settings WHERE agent_id=p_agent_id;
  IF fs.fee_plan_id IS NOT NULL THEN
    SELECT * INTO plan FROM public.dv_accounting_fee_plans WHERE id=fs.fee_plan_id;
  END IF;

  SELECT * INTO rule
  FROM public.dv_accounting_agent_fee_rules
  WHERE agent_id=p_agent_id AND active
    AND effective_from<=p_as_of
    AND (effective_to IS NULL OR effective_to>=p_as_of)
  ORDER BY effective_from DESC,created_at DESC LIMIT 1;

  IF t.transaction_type='LEASE' THEN
    split_pct:=COALESCE(
      rule.commission_split_lease_percent,
      fs.commission_split_lease_override_percent,
      plan.commission_split_lease_percent,
      100
    );
  ELSE
    split_pct:=COALESCE(
      rule.commission_split_buy_sell_percent,
      fs.commission_split_buy_sell_override_percent,
      fs.commission_split_override_percent,
      plan.commission_split_buy_sell_percent,
      plan.commission_split_percent,
      85
    );
  END IF;

  desk_fee:=COALESCE(rule.desk_fee,fs.desk_fee_override,plan.desk_fee,0);

  IF t.market_segment='COMMERCIAL' AND t.transaction_type='LEASE' THEN
    admin_type:=COALESCE(rule.admin_fee_commercial_lease_type,fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_commercial_lease_value,fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
  ELSIF t.market_segment='COMMERCIAL' THEN
    admin_type:=COALESCE(rule.admin_fee_commercial_buy_sell_type,fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_commercial_buy_sell_value,fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
  ELSIF t.transaction_type='LEASE' THEN
    admin_type:=COALESCE(rule.admin_fee_lease_type,fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_lease_value,fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
  ELSE
    admin_type:=COALESCE(rule.admin_fee_buy_sell_type,fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
    admin_value:=COALESCE(rule.admin_fee_buy_sell_value,fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
  END IF;

  IF t.transaction_type='LEASE' THEN
    lead_type:=COALESCE(rule.lead_fee_lease_type,fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
    lead_value:=COALESCE(rule.lead_fee_lease_value,fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
  ELSE
    lead_type:=COALESCE(rule.lead_fee_buy_sell_type,fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
    lead_value:=COALESCE(rule.lead_fee_buy_sell_value,fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
  END IF;

  agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);
  IF admin_type='PERCENT' THEN admin_fee:=ROUND(COALESCE(p_gross_commission,0)*admin_value/100,2); ELSE admin_fee:=ROUND(admin_value,2); END IF;
  IF lead_type='PERCENT' THEN lead_fee:=ROUND(COALESCE(p_gross_commission,0)*lead_value/100,2); ELSE lead_fee:=ROUND(lead_value,2); END IF;

  RETURN jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'brokerage_share_percent',100-split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'total_transaction_fees',ROUND(admin_fee+lead_fee,2),
    'net_transaction_commission',ROUND(agent_share-admin_fee-lead_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
END $$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) TO authenticated;
NOTIFY pgrst, 'reload schema';
