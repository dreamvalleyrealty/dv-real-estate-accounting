-- 0041_transaction_rpc_schema_cache_repair.sql
-- Ensure transaction commission workflow RPCs exist with the exact PostgREST
-- signature used by the Transactions workspace, and refresh the API schema cache.

CREATE OR REPLACE FUNCTION public.dv_accounting_approve_transaction_commission(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
BEGIN
  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  IF t.status IN ('FINALIZED','CLOSED') THEN
    RAISE EXCEPTION 'Finalized or closed transaction commission cannot be changed';
  END IF;

  IF COALESCE(t.gross_commission,0) <= 0
     AND COALESCE(t.agent_commission,0) <= 0 THEN
    RAISE EXCEPTION 'Enter and verify the commission amount before approval';
  END IF;

  UPDATE public.dv_accounting_transactions
  SET commission_approved = true,
      commission_approved_at = COALESCE(commission_approved_at, now()),
      commission_approved_amount = COALESCE(t.gross_commission,0),
      commission_approved_agent_payable = COALESCE(t.agent_commission,0)
  WHERE id = t.id;

  RETURN jsonb_build_object(
    'ok', true,
    'transaction_id', t.id,
    'approved_amount', COALESCE(t.gross_commission,0),
    'agent_payable', COALESCE(t.agent_commission,0)
  );
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_approve_transaction_commission(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_approve_transaction_commission(uuid) TO authenticated;

-- Also refresh the close workflow RPC in case the database was installed
-- from a partial transaction-workspace migration.
CREATE OR REPLACE FUNCTION public.dv_accounting_close_transaction(p_transaction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  v_commission_id uuid;
  agent_amt numeric(14,2);
  gross_amt numeric(14,2);
BEGIN
  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  IF t.status <> 'FINALIZED' THEN
    RAISE EXCEPTION 'Finalize the transaction accounting before closing it';
  END IF;

  IF NOT COALESCE(t.commission_approved,false) THEN
    RAISE EXCEPTION 'Commission amount must be approved before closing the transaction';
  END IF;

  IF t.close_date IS NULL THEN
    RAISE EXCEPTION 'Close date is required before closing the transaction';
  END IF;

  IF t.agent_id IS NULL THEN
    RAISE EXCEPTION 'Deal agent is required before sending the commission to payroll';
  END IF;

  gross_amt := COALESCE(t.commission_approved_amount,t.gross_commission,0);
  agent_amt := COALESCE(t.commission_approved_agent_payable,t.agent_commission,0);
  v_commission_id := t.commission_id;

  IF v_commission_id IS NULL THEN
    SELECT id INTO v_commission_id
    FROM public.dv_accounting_commissions
    WHERE transaction_id = t.id
    ORDER BY id
    LIMIT 1;

    IF v_commission_id IS NULL THEN
      INSERT INTO public.dv_accounting_commissions(
        transaction_id, agent_id, gross_commission, brokerage_share, agent_share, status
      )
      VALUES(
        t.id, t.agent_id, gross_amt,
        GREATEST(gross_amt-agent_amt,0),
        agent_amt,
        'UNPAID'
      )
      RETURNING id INTO v_commission_id;
    ELSE
      UPDATE public.dv_accounting_commissions
      SET agent_id = t.agent_id,
          gross_commission = gross_amt,
          brokerage_share = GREATEST(gross_amt-agent_amt,0),
          agent_share = agent_amt
      WHERE id = v_commission_id;
    END IF;
  ELSE
    UPDATE public.dv_accounting_commissions
    SET status = CASE WHEN status='PAID' THEN status ELSE 'UNPAID' END,
        agent_id = t.agent_id,
        gross_commission = gross_amt,
        brokerage_share = GREATEST(gross_amt-agent_amt,0),
        agent_share = agent_amt
    WHERE id = v_commission_id;
  END IF;

  UPDATE public.dv_accounting_transactions
  SET status = 'CLOSED',
      closed_at = COALESCE(closed_at,now()),
      closed_by = auth.uid(),
      commission_payroll_status =
        CASE WHEN EXISTS (
          SELECT 1
          FROM public.dv_accounting_commission_cheques ch
          WHERE ch.commission_id = v_commission_id
            AND ch.status = 'ISSUED'
        ) THEN 'PAID' ELSE 'READY' END,
      commission_id = v_commission_id
  WHERE id = t.id;

  RETURN jsonb_build_object(
    'ok', true,
    'transaction_id', t.id,
    'commission_id', v_commission_id,
    'commission_payroll_status', 'READY',
    'agent_payable', agent_amt
  );
END
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_close_transaction(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_close_transaction(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
