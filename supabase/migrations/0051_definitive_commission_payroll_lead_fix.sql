-- 0051: definitive brokerage-lead commission payroll correction.
-- A lead fee is deductible only when the transaction is marked as a brokerage lead.
-- Commission records created by the transaction close workflow already store the
-- agent payable after transaction fees, so payroll must not subtract those fees again.

DO $$
DECLARE
  c record;
  t record;
  ai record;
  lead_to_restore numeric(14,2);
BEGIN
  FOR c IN
    SELECT id, transaction_id, agent_id, agent_share, gross_commission
    FROM public.dv_accounting_commissions
    WHERE status <> 'PAID'
  LOOP
    SELECT id, is_brokerage_lead, agent_commission
      INTO t
    FROM public.dv_accounting_transactions
    WHERE id=c.transaction_id;

    IF t.id IS NOT NULL AND NOT COALESCE(t.is_brokerage_lead,false) THEN
      SELECT lead_fee, net_payable, lead_fee_applies
        INTO ai
      FROM public.dv_accounting_transaction_agent_info
      WHERE transaction_id=c.transaction_id
      LIMIT 1;

      lead_to_restore := GREATEST(COALESCE(ai.lead_fee,0),0);

      IF lead_to_restore > 0 THEN
        UPDATE public.dv_accounting_commissions
        SET agent_share=ROUND(COALESCE(agent_share,0)+lead_to_restore,2),
            brokerage_share=GREATEST(
              ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+lead_to_restore),2),0
            )
        WHERE id=c.id;

        UPDATE public.dv_accounting_transactions
        SET agent_commission=ROUND(COALESCE(agent_commission,0)+lead_to_restore,2),
            commission_approved_agent_payable=CASE
              WHEN COALESCE(commission_approved,false)
              THEN ROUND(COALESCE(commission_approved_agent_payable,0)+lead_to_restore,2)
              ELSE commission_approved_agent_payable
            END
        WHERE id=c.transaction_id;

        UPDATE public.dv_accounting_transaction_agent_info
        SET lead_fee=0,
            lead_fee_applies=false,
            net_payable=ROUND(COALESCE(net_payable,0)+lead_to_restore,2)
        WHERE transaction_id=c.transaction_id;
      END IF;
    END IF;
  END LOOP;
END $$;

-- Keep the full transaction-type-aware fee engine from migration 0040, with the
-- only behavioral change being that lead fees require is_brokerage_lead=true.
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

  IF COALESCE(t.is_brokerage_lead,false) THEN
    IF lead_type='PERCENT' THEN lead_fee:=ROUND(COALESCE(p_gross_commission,0)*lead_value/100,2); ELSE lead_fee:=ROUND(lead_value,2); END IF;
  ELSE
    lead_fee:=0;
  END IF;

  RETURN jsonb_build_object(
    'agent_share',agent_share,
    'commission_split_percent',split_pct,
    'brokerage_share_percent',100-split_pct,
    'desk_fee',desk_fee,
    'admin_fee',admin_fee,
    'lead_fee',lead_fee,
    'lead_fee_applies',COALESCE(t.is_brokerage_lead,false),
    'total_transaction_fees',ROUND(admin_fee+lead_fee,2),
    'net_transaction_commission',ROUND(agent_share-admin_fee-lead_fee-desk_fee,2),
    'fee_rule_id',rule.id,
    'effective_date',p_as_of
  );
END $$;

-- Payroll/cheque must use the commission's stored approved agent payable as the
-- net commission before HST. Do not deduct transaction fees a second time.
CREATE OR REPLACE FUNCTION public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text DEFAULT NULL,
  p_cheque_date date DEFAULT current_date,
  p_adjustment numeric DEFAULT 0,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  gross_amt numeric(14,2);
  agent_share numeric(14,2);
  transaction_fees numeric(14,2);
  outstanding_fees numeric(14,2);
  total_fees numeric(14,2);
  net_agent_before_hst numeric(14,2);
  hst_rate numeric(6,3) := 13;
  agent_hst numeric(14,2) := 0;
  client_hst numeric(14,2) := 0;
  brokerage_hst numeric(14,2) := 0;
BEGIN
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF c.status='PAID' THEN RAISE EXCEPTION 'Commission has already been paid'; END IF;
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;
  SELECT * INTO agent FROM public.dv_accounting_agents WHERE id=c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt:=COALESCE(c.gross_commission,t.gross_commission,0);
  calc:=public.dv_accounting_calculate_commission_fees(c.agent_id,c.transaction_id,gross_amt,COALESCE(t.transaction_date,p_cheque_date));
  transaction_fees:=ROUND(COALESCE((calc->>'admin_fee')::numeric,0)+COALESCE((calc->>'lead_fee')::numeric,0)+COALESCE((calc->>'desk_fee')::numeric,0),2);

  -- c.agent_share is the approved agent payable created by close_transaction.
  -- It already reflects transaction-level fees, including the repaired lead rule.
  agent_share:=ROUND(COALESCE(c.agent_share,t.agent_commission,0),2);

  SELECT COALESCE(SUM(amount),0) INTO outstanding_fees
  FROM public.dv_accounting_commission_charges
  WHERE agent_id=c.agent_id AND status='OPEN' AND applied_to_cheque_id IS NULL
    AND COALESCE(commission_id::text,'')<>c.id::text;
  total_fees:=ROUND(outstanding_fees,2);
  net_agent_before_hst:=GREATEST(agent_share-total_fees,0);

  IF NULLIF(BTRIM(COALESCE(agent.hst_number,'')),'') IS NOT NULL THEN
    agent_hst:=ROUND(net_agent_before_hst*hst_rate/100,2);
  END IF;
  client_hst:=CASE WHEN COALESCE(t.hst_amount,0)>0 THEN ROUND(t.hst_amount,2) ELSE ROUND(gross_amt*hst_rate/100,2) END;
  brokerage_hst:=GREATEST(client_hst-agent_hst,0);

  INSERT INTO public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,agent_share,total_fees,adjustments,status,issued_at,notes,
    agent_hst_number,agent_hst_rate,agent_hst_amount,brokerage_hst_amount,client_hst_amount
  ) VALUES(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,gross_amt,agent_share,total_fees,COALESCE(p_adjustment,0),'ISSUED',now(),p_notes,
    NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),hst_rate,agent_hst,brokerage_hst,client_hst
  ) RETURNING id INTO cheque_id;

  INSERT INTO public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,source_rule_id
  )
  SELECT c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
    CASE WHEN x.charge_type IN ('ADMIN_FEE','LEAD_FEE') THEN (calc->>'fee_rule_id')::uuid ELSE NULL END
  FROM jsonb_to_recordset(jsonb_build_array(
    jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',0),
    jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',0)
  )) AS x(charge_type text,description text,amount numeric)
  WHERE x.amount>0;

  UPDATE public.dv_accounting_commissions SET status='PAID',paid_date=p_cheque_date WHERE id=c.id;

  RETURN jsonb_build_object(
    'cheque_id',cheque_id,'commission_id',c.id,'agent_share',agent_share,
    'agent_net_before_hst',net_agent_before_hst,'agent_hst_number',NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),
    'agent_hst_rate',hst_rate,'agent_hst_amount',agent_hst,'brokerage_hst_amount',brokerage_hst,'client_hst_amount',client_hst,
    'total_fees',total_fees,'transaction_fees',transaction_fees,'lead_fee_amount',COALESCE((calc->>'lead_fee')::numeric,0),
    'net_amount',net_agent_before_hst+COALESCE(p_adjustment,0)+agent_hst,'calculation',calc
  );
END $$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) TO authenticated;
NOTIFY pgrst,'reload schema';
