-- Apply Dream Valley's $500 minimum brokerage share to buy/sell transactions only.
-- Lease transactions and 100% agent-split plans retain their configured split.
CREATE OR REPLACE FUNCTION public.dv_accounting_calculate_commission_fees(p_agent_id uuid, p_transaction_id uuid, p_gross_commission numeric, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  brokerage_share numeric := 0;
  minimum_brokerage_share_applied boolean := false;
  is_broker_100 boolean := false;
BEGIN
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  SELECT * INTO fs FROM public.dv_accounting_agent_fee_settings WHERE agent_id=p_agent_id;
  IF fs.fee_plan_id IS NOT NULL THEN
    SELECT * INTO plan FROM public.dv_accounting_fee_plans WHERE id=fs.fee_plan_id;
  END IF;
  is_broker_100 := regexp_replace(lower(coalesce(plan.name,'')), '[^a-z0-9]', '', 'g') LIKE 'broker100%';

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

  -- Broker 100% is a brokerage-retained plan; it overrides any fee-rule or agent split override.
  IF is_broker_100 THEN split_pct:=0; END IF;

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

  IF t.transaction_type <> 'LEASE'
     AND split_pct < 100
     AND COALESCE(p_gross_commission,0) > 0 THEN
    brokerage_share:=LEAST(
      ROUND(COALESCE(p_gross_commission,0),2),
      GREATEST(ROUND(COALESCE(p_gross_commission,0)*(100-split_pct)/100,2),500)
    );
    minimum_brokerage_share_applied :=
      brokerage_share > ROUND(COALESCE(p_gross_commission,0)*(100-split_pct)/100,2);
    agent_share:=ROUND(GREATEST(COALESCE(p_gross_commission,0)-brokerage_share,0),2);
  ELSE
    agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);
    brokerage_share:=ROUND(COALESCE(p_gross_commission,0)-agent_share,2);
  END IF;
  IF admin_type='PERCENT' THEN admin_fee:=ROUND(COALESCE(p_gross_commission,0)*admin_value/100,2); ELSE admin_fee:=ROUND(admin_value,2); END IF;

  IF COALESCE(t.is_brokerage_lead,false) THEN
    IF lead_type='PERCENT' THEN lead_fee:=ROUND(COALESCE(p_gross_commission,0)*lead_value/100,2); ELSE lead_fee:=ROUND(lead_value,2); END IF;
  ELSE
    lead_fee:=0;
  END IF;

  RETURN jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'brokerage_share_percent',CASE WHEN COALESCE(p_gross_commission,0)>0 THEN ROUND(brokerage_share*100/COALESCE(p_gross_commission,0),4) ELSE 100-split_pct END,
    'brokerage_share',brokerage_share,
    'minimum_brokerage_share_applied',minimum_brokerage_share_applied,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'lead_fee_applies',COALESCE(t.is_brokerage_lead,false),
    'total_transaction_fees',ROUND(admin_fee+lead_fee,2),
    'net_transaction_commission',GREATEST(ROUND(agent_share-admin_fee-lead_fee-desk_fee,2),0),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
END $function$;

