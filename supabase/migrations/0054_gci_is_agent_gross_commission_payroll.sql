-- Repair existing unpaid commissions whose saved agent-info snapshot includes
-- a lead fee even though the transaction is not a brokerage lead. Also protect
-- cheque issuance against any remaining stale snapshot.
DO $$
DECLARE
  c record;
  ai record;
  lead_to_restore numeric(14,2);
BEGIN
  FOR c IN
    SELECT id, transaction_id, agent_share, gross_commission
    FROM public.dv_accounting_commissions
    WHERE status <> 'PAID'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.dv_accounting_transactions t
      WHERE t.id=c.transaction_id AND NOT COALESCE(t.is_brokerage_lead,false)
    ) THEN
      SELECT lead_fee, net_payable INTO ai
      FROM public.dv_accounting_transaction_agent_info
      WHERE transaction_id=c.transaction_id
      LIMIT 1;
      lead_to_restore:=GREATEST(COALESCE(ai.lead_fee,0),0);
      IF lead_to_restore>0
         AND ROUND(COALESCE(c.agent_share,0),2) <= ROUND(COALESCE(ai.net_payable,c.agent_share,0),2)+0.01 THEN
        UPDATE public.dv_accounting_commissions
        SET agent_share=ROUND(COALESCE(agent_share,0)+lead_to_restore,2),
            brokerage_share=GREATEST(ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+lead_to_restore),2),0)
        WHERE id=c.id;
        UPDATE public.dv_accounting_transactions
        SET agent_commission=ROUND(COALESCE(agent_commission,0)+lead_to_restore,2),
            commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
              THEN ROUND(COALESCE(commission_approved_agent_payable,0)+lead_to_restore,2)
              ELSE commission_approved_agent_payable END
        WHERE id=c.transaction_id;
        UPDATE public.dv_accounting_transaction_agent_info
        SET lead_fee=0, lead_fee_applies=false,
            net_payable=ROUND(COALESCE(net_payable,0)+lead_to_restore,2)
        WHERE transaction_id=c.transaction_id;
      END IF;
    END IF;
  END LOOP;
END $$;

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
  ai record;
  lead_to_restore numeric(14,2) := 0;
BEGIN
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF c.status='PAID' THEN RAISE EXCEPTION 'Commission has already been paid'; END IF;
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  -- Last-line safeguard: restore a saved lead deduction for non-lead transactions
  -- before issuing payment. The condition prevents a second restoration.
  IF NOT COALESCE(t.is_brokerage_lead,false) THEN
    SELECT lead_fee, net_payable INTO ai
    FROM public.dv_accounting_transaction_agent_info
    WHERE transaction_id=c.transaction_id
    LIMIT 1;
    lead_to_restore:=GREATEST(COALESCE(ai.lead_fee,0),0);
    IF lead_to_restore>0
       AND ROUND(COALESCE(c.agent_share,0),2) <= ROUND(COALESCE(ai.net_payable,c.agent_share,0),2)+0.01 THEN
      UPDATE public.dv_accounting_commissions
      SET agent_share=ROUND(COALESCE(agent_share,0)+lead_to_restore,2),
          brokerage_share=GREATEST(ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+lead_to_restore),2),0)
      WHERE id=c.id;
      UPDATE public.dv_accounting_transactions
      SET agent_commission=ROUND(COALESCE(agent_commission,0)+lead_to_restore,2),
          commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
            THEN ROUND(COALESCE(commission_approved_agent_payable,0)+lead_to_restore,2)
            ELSE commission_approved_agent_payable END
      WHERE id=c.transaction_id;
      UPDATE public.dv_accounting_transaction_agent_info
      SET lead_fee=0, lead_fee_applies=false,
          net_payable=ROUND(COALESCE(net_payable,0)+lead_to_restore,2)
      WHERE transaction_id=c.transaction_id;
      SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;
      SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
    END IF;
  END IF;

  SELECT * INTO agent FROM public.dv_accounting_agents WHERE id=c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt:=COALESCE(c.gross_commission,t.gross_commission,0);
  calc:=public.dv_accounting_calculate_commission_fees(c.agent_id,c.transaction_id,gross_amt,COALESCE(t.transaction_date,p_cheque_date));
  transaction_fees:=ROUND(COALESCE((calc->>'admin_fee')::numeric,0)+COALESCE((calc->>'lead_fee')::numeric,0)+COALESCE((calc->>'desk_fee')::numeric,0),2);

  -- Calculate agent payable from GCI less applicable transaction fees; GCI is already the agent gross commission.
  -- This prevents a stale approved amount from preserving an incorrect lead deduction
  -- or omitting the configured admin fee.
  agent_share:=GREATEST(ROUND(
    gross_amt - transaction_fees,2),0);

  UPDATE public.dv_accounting_commissions
  SET agent_share=GREATEST(ROUND(
        gross_amt - transaction_fees,2),0),
      brokerage_share=GREATEST(ROUND(COALESCE(gross_commission,0)-
        GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,c.agent_share,t.agent_commission,0)
        - transaction_fees,2),0),2),0)
  WHERE id=c.id;
  UPDATE public.dv_accounting_transactions
  SET agent_commission=agent_share,
      commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
        THEN agent_share ELSE commission_approved_agent_payable END
  WHERE id=t.id;
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;

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
