-- 0050: enforce brokerage-lead gating in the core fee engine and repair
-- outstanding commission payroll records that were created with a lead fee
-- even though the transaction was not a brokerage lead.
--
-- IMPORTANT: repair existing outstanding records BEFORE replacing the fee
-- function, so the old function can tell us the lead amount that was embedded
-- in total_fees.

DO $$
DECLARE
  c record;
  t record;
  calc jsonb;
  old_lead numeric(14,2);
BEGIN
  -- Existing commission records do not store total_fees. The agent_share
  -- represents the payable amount handed off from the transaction, so for
  -- outstanding non-lead transactions we add back only the lead fee that
  -- was incorrectly deducted.
  FOR c IN
    SELECT id, agent_id, transaction_id, gross_commission, agent_share
    FROM public.dv_accounting_commissions
    WHERE status <> 'PAID'
  LOOP
    SELECT id, is_brokerage_lead, agent_commission
      INTO t
    FROM public.dv_accounting_transactions
    WHERE id=c.transaction_id;

    IF t.id IS NOT NULL AND NOT COALESCE(t.is_brokerage_lead,false) THEN
      calc := public.dv_accounting_calculate_commission_fees(
        c.agent_id,
        c.transaction_id,
        COALESCE(c.gross_commission,0),
        current_date
      );
      old_lead := COALESCE((calc->>'lead_fee')::numeric,0);

      IF old_lead > 0 THEN
        UPDATE public.dv_accounting_commissions
        SET agent_share=ROUND(COALESCE(agent_share,0)+old_lead,2),
            brokerage_share=GREATEST(
              ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+old_lead),2),0
            )
        WHERE id=c.id;

        -- Keep the transaction's approved/payroll amount synchronized with
        -- the repaired commission record.
        UPDATE public.dv_accounting_transactions
        SET agent_commission=ROUND(COALESCE(agent_commission,0)+old_lead,2),
            commission_approved_agent_payable=CASE
              WHEN COALESCE(commission_approved,false)
              THEN ROUND(COALESCE(commission_approved_agent_payable,0)+old_lead,2)
              ELSE commission_approved_agent_payable
            END
        WHERE id=c.transaction_id;
      END IF;
    END IF;
  END LOOP;
END $$;

-- Replace the core fee engine. A configured lead percentage/value is only
-- applied when the transaction is explicitly marked as a brokerage lead.
CREATE OR REPLACE FUNCTION public.dv_accounting_calculate_commission_fees(
  p_agent_id uuid,
  p_transaction_id uuid,
  p_gross_commission numeric,
  p_as_of date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  a public.dv_accounting_agents%rowtype;
  t public.dv_accounting_transactions%rowtype;
  fs public.dv_accounting_agent_fee_settings%rowtype;
  plan public.dv_accounting_fee_plans%rowtype;
  rule public.dv_accounting_agent_fee_rules%rowtype;
  split_pct numeric := 90;
  admin_type text;
  admin_value numeric := 0;
  lead_type text;
  lead_value numeric := 0;
  admin_fee numeric := 0;
  lead_fee numeric := 0;
  agent_share numeric := 0;
  desk_fee numeric := 0;
BEGIN
  SELECT * INTO a FROM public.dv_accounting_agents WHERE id=p_agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=p_transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  SELECT * INTO rule
  FROM public.dv_accounting_agent_fee_rules
  WHERE agent_id=p_agent_id AND active
    AND effective_from<=p_as_of
    AND (effective_to IS NULL OR effective_to>=p_as_of)
  ORDER BY effective_from DESC,created_at DESC
  LIMIT 1;

  IF rule.id IS NOT NULL THEN
    split_pct:=COALESCE(rule.commission_split_percent,split_pct);
    desk_fee:=COALESCE(rule.desk_fee,0);

    IF t.market_segment='COMMERCIAL' AND t.side='LEASE' THEN
      admin_type:=COALESCE(rule.admin_fee_commercial_lease_type,'AMOUNT');
      admin_value:=COALESCE(rule.admin_fee_commercial_lease_value,0);
    ELSIF t.market_segment='COMMERCIAL' THEN
      admin_type:=COALESCE(rule.admin_fee_commercial_buy_sell_type,'AMOUNT');
      admin_value:=COALESCE(rule.admin_fee_commercial_buy_sell_value,0);
    ELSIF t.side='LEASE' THEN
      admin_type:=COALESCE(rule.admin_fee_lease_type,'AMOUNT');
      admin_value:=COALESCE(rule.admin_fee_lease_value,0);
    ELSE
      admin_type:=COALESCE(rule.admin_fee_buy_sell_type,'AMOUNT');
      admin_value:=COALESCE(rule.admin_fee_buy_sell_value,0);
    END IF;

    IF t.side='LEASE' THEN
      lead_type:=COALESCE(rule.lead_fee_lease_type,'AMOUNT');
      lead_value:=COALESCE(rule.lead_fee_lease_value,0);
    ELSE
      lead_type:=COALESCE(rule.lead_fee_buy_sell_type,'AMOUNT');
      lead_value:=COALESCE(rule.lead_fee_buy_sell_value,0);
    END IF;
  ELSE
    SELECT * INTO fs
    FROM public.dv_accounting_agent_fee_settings
    WHERE agent_id=p_agent_id;

    IF fs.id IS NOT NULL THEN
      IF fs.fee_plan_id IS NOT NULL THEN
        SELECT * INTO plan FROM public.dv_accounting_fee_plans WHERE id=fs.fee_plan_id;
      END IF;

      split_pct:=COALESCE(fs.commission_split_override_percent,plan.commission_split_percent,split_pct);
      desk_fee:=COALESCE(fs.desk_fee_override,plan.desk_fee,0);

      IF t.market_segment='COMMERCIAL' AND t.side='LEASE' THEN
        admin_type:=COALESCE(fs.admin_fee_commercial_lease_type,plan.admin_fee_commercial_lease_type,'AMOUNT');
        admin_value:=COALESCE(fs.admin_fee_commercial_lease_value,plan.admin_fee_commercial_lease_value,0);
      ELSIF t.market_segment='COMMERCIAL' THEN
        admin_type:=COALESCE(fs.admin_fee_commercial_buy_sell_type,plan.admin_fee_commercial_buy_sell_type,'AMOUNT');
        admin_value:=COALESCE(fs.admin_fee_commercial_buy_sell_value,plan.admin_fee_commercial_buy_sell_value,0);
      ELSIF t.side='LEASE' THEN
        admin_type:=COALESCE(fs.admin_fee_lease_type,plan.admin_fee_lease_type,'AMOUNT');
        admin_value:=COALESCE(fs.admin_fee_lease_value,plan.admin_fee_lease_value,0);
      ELSE
        admin_type:=COALESCE(fs.admin_fee_buy_sell_type,plan.admin_fee_buy_sell_type,'AMOUNT');
        admin_value:=COALESCE(fs.admin_fee_buy_sell_value,plan.admin_fee_buy_sell_value,0);
      END IF;

      IF t.side='LEASE' THEN
        lead_type:=COALESCE(fs.lead_fee_lease_type,plan.lead_fee_lease_type,'AMOUNT');
        lead_value:=COALESCE(fs.lead_fee_lease_value,plan.lead_fee_lease_value,0);
      ELSE
        lead_type:=COALESCE(fs.lead_fee_buy_sell_type,plan.lead_fee_buy_sell_type,'AMOUNT');
        lead_value:=COALESCE(fs.lead_fee_buy_sell_value,plan.lead_fee_buy_sell_value,0);
      END IF;
    ELSE
      split_pct:=COALESCE(plan.commission_split_percent,split_pct);
      desk_fee:=COALESCE(plan.desk_fee,0);
    END IF;
  END IF;

  agent_share:=ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2);

  IF admin_type='PERCENT' THEN
    admin_fee:=ROUND(COALESCE(p_gross_commission,0)*admin_value/100,2);
  ELSE
    admin_fee:=ROUND(admin_value,2);
  END IF;

  -- Lead fee is conditional on the transaction flag. The configured fee is
  -- ignored for ordinary brokerage transactions.
  IF COALESCE(t.is_brokerage_lead,false) THEN
    IF lead_type='PERCENT' THEN
      lead_fee:=ROUND(COALESCE(p_gross_commission,0)*lead_value/100,2);
    ELSE
      lead_fee:=ROUND(lead_value,2);
    END IF;
  ELSE
    lead_fee:=0;
  END IF;

  RETURN jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'lead_fee_applies',COALESCE(t.is_brokerage_lead,false),
    'total_transaction_fees',ROUND(admin_fee+lead_fee,2),
    'net_transaction_commission',ROUND(agent_share-admin_fee-lead_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
END $$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) TO authenticated;
NOTIFY pgrst, 'reload schema';
