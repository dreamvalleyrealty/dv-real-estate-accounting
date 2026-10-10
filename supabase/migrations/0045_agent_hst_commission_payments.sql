-- 0045: pay HST to registered agents and include agent HST as an ITC in the HST working paper.
-- Ontario default rate is 13%; store the rate and amounts on each issued cheque as an audit snapshot.

ALTER TABLE public.dv_accounting_commission_cheques
  ADD COLUMN IF NOT EXISTS agent_hst_number text,
  ADD COLUMN IF NOT EXISTS agent_hst_rate numeric(6,3) NOT NULL DEFAULT 13,
  ADD COLUMN IF NOT EXISTS agent_hst_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS brokerage_hst_amount numeric(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS client_hst_amount numeric(14,2) NOT NULL DEFAULT 0;

-- The agent's HST is part of the cheque payable, not a deduction from their commission share.
ALTER TABLE public.dv_accounting_commission_cheques
  DROP COLUMN IF EXISTS net_amount;
ALTER TABLE public.dv_accounting_commission_cheques
  ADD COLUMN net_amount numeric(14,2)
  GENERATED ALWAYS AS (agent_share - total_fees + adjustments + agent_hst_amount) STORED;

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
  total_fees numeric(14,2);
  agent_share numeric(14,2);
  gross_amt numeric(14,2);
  hst_rate numeric(6,3) := 13;
  agent_hst numeric(14,2) := 0;
  client_hst numeric(14,2) := 0;
  brokerage_hst numeric(14,2) := 0;
BEGIN
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF c.status='PAID' THEN RAISE EXCEPTION 'Commission has already been paid'; END IF;

  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
  SELECT * INTO agent FROM public.dv_accounting_agents WHERE id=c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt := COALESCE(c.gross_commission,t.gross_commission,0);
  calc := public.dv_accounting_calculate_commission_fees(
    c.agent_id,c.transaction_id,gross_amt,COALESCE(t.transaction_date,p_cheque_date)
  );
  agent_share := COALESCE((calc->>'agent_share')::numeric,0);
  total_fees := COALESCE((calc->>'admin_fee')::numeric,0)+COALESCE((calc->>'lead_fee')::numeric,0);

  -- Only pay HST when the agent has an HST registration number on their current profile.
  IF NULLIF(BTRIM(COALESCE(agent.hst_number,'')),'') IS NOT NULL THEN
    agent_hst := ROUND(agent_share * hst_rate / 100,2);
  END IF;

  -- The transaction's HST is the tax charged on the full commission. If it was not entered,
  -- use the Ontario default to provide a clear snapshot on the cheque.
  client_hst := CASE
    WHEN COALESCE(t.hst_amount,0) > 0 THEN ROUND(t.hst_amount,2)
    ELSE ROUND(gross_amt * hst_rate / 100,2)
  END;
  brokerage_hst := GREATEST(client_hst-agent_hst,0);

  INSERT INTO public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,
    agent_share,total_fees,adjustments,status,issued_at,notes,
    agent_hst_number,agent_hst_rate,agent_hst_amount,brokerage_hst_amount,client_hst_amount
  )
  VALUES(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,gross_amt,
    agent_share,total_fees,COALESCE(p_adjustment,0),'ISSUED',now(),p_notes,
    NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),hst_rate,agent_hst,brokerage_hst,client_hst
  ) RETURNING id INTO cheque_id;

  INSERT INTO public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,source_rule_id
  )
  SELECT c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
         CASE WHEN x.charge_type IN ('ADMIN_FEE','LEAD_FEE') THEN (calc->>'fee_rule_id')::uuid ELSE NULL END
  FROM jsonb_to_recordset(
    jsonb_build_array(
      jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',COALESCE((calc->>'admin_fee')::numeric,0)),
      jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',COALESCE((calc->>'lead_fee')::numeric,0))
    )
  ) AS x(charge_type text,description text,amount numeric);

  UPDATE public.dv_accounting_commissions
  SET status='PAID',paid_date=p_cheque_date
  WHERE id=c.id;

  RETURN jsonb_build_object(
    'cheque_id',cheque_id,
    'commission_id',c.id,
    'agent_share',agent_share,
    'agent_hst_number',NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),
    'agent_hst_rate',hst_rate,
    'agent_hst_amount',agent_hst,
    'brokerage_hst_amount',brokerage_hst,
    'client_hst_amount',client_hst,
    'total_fees',total_fees,
    'net_amount',agent_share-total_fees+COALESCE(p_adjustment,0)+agent_hst,
    'calculation',calc
  );
END $$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_issue_commission_cheque(uuid,text,date,numeric,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
