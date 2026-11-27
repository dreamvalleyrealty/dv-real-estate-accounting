-- Track each partial agent-charge deduction against the commission payment that funded it.
-- Outstanding balances are reduced by direct payments and by commission allocations.

CREATE TABLE IF NOT EXISTS public.dv_accounting_agent_charge_commission_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.dv_accounting_companies(id) ON DELETE RESTRICT,
  agent_id uuid NOT NULL REFERENCES public.dv_accounting_agents(id) ON DELETE RESTRICT,
  charge_id uuid NOT NULL REFERENCES public.dv_accounting_commission_charges(id) ON DELETE RESTRICT,
  commission_cheque_id uuid NOT NULL REFERENCES public.dv_accounting_commission_cheques(id) ON DELETE RESTRICT,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dv_agent_charge_commission_allocations_unique
    UNIQUE (charge_id, commission_cheque_id)
);

CREATE INDEX IF NOT EXISTS idx_dv_agent_charge_commission_allocations_agent
  ON public.dv_accounting_agent_charge_commission_allocations(agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dv_agent_charge_commission_allocations_cheque
  ON public.dv_accounting_agent_charge_commission_allocations(commission_cheque_id);
CREATE INDEX IF NOT EXISTS idx_dv_agent_charge_commission_allocations_charge
  ON public.dv_accounting_agent_charge_commission_allocations(charge_id);

ALTER TABLE public.dv_accounting_agent_charge_commission_allocations ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.dv_accounting_agent_charge_commission_allocations TO authenticated;

DROP POLICY IF EXISTS dv_agent_charge_commission_allocations_select
  ON public.dv_accounting_agent_charge_commission_allocations;
CREATE POLICY dv_agent_charge_commission_allocations_select
  ON public.dv_accounting_agent_charge_commission_allocations
  FOR SELECT TO authenticated
  USING (
    public.dv_accounting_has_permission_all_scope('commission.view')
    OR public.dv_accounting_has_permission_all_scope('fees.manage')
  );

DROP TRIGGER IF EXISTS dv_accounting_audit_trigger
  ON public.dv_accounting_agent_charge_commission_allocations;
CREATE TRIGGER dv_accounting_audit_trigger
  AFTER INSERT OR UPDATE OR DELETE
  ON public.dv_accounting_agent_charge_commission_allocations
  FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_capture_audit_log();

-- The old boolean parameter remains for RPC compatibility. All eligible agent charges
-- are now deducted automatically, up to the amount available on the commission payment.
CREATE OR REPLACE FUNCTION public.dv_accounting_issue_commission_cheque(
  p_commission_id uuid,
  p_cheque_number text DEFAULT NULL,
  p_cheque_date date DEFAULT current_date,
  p_adjustment numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_deduct_desk_fees boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  c public.dv_accounting_commissions%ROWTYPE;
  t public.dv_accounting_transactions%ROWTYPE;
  a public.dv_accounting_agents%ROWTYPE;
  calc jsonb;
  cheque_id uuid;
  transaction_fees numeric(14,2) := 0;
  total_fees numeric(14,2) := 0;
  agent_share numeric(14,2) := 0;
  agent_hst_number text;
  agent_hst_rate numeric(6,3) := 13;
  agent_hst numeric(14,2) := 0;
  client_hst numeric(14,2) := 0;
  brokerage_hst numeric(14,2) := 0;
  gross_amt numeric(14,2) := 0;
  available_before_charges numeric(14,2) := 0;
  remaining_capacity numeric(14,2) := 0;
  total_outstanding numeric(14,2) := 0;
  total_charge_deduction numeric(14,2) := 0;
  desk_fees numeric(14,2) := 0;
  recurring_fees numeric(14,2) := 0;
  service_fees numeric(14,2) := 0;
  general_fees numeric(14,2) := 0;
  charge_total numeric(14,2) := 0;
  direct_paid numeric(14,2) := 0;
  previously_allocated numeric(14,2) := 0;
  charge_balance numeric(14,2) := 0;
  amount_to_apply numeric(14,2) := 0;
  balance_after numeric(14,2) := 0;
  allocations jsonb := '[]'::jsonb;
  charge_row record;
  allocation_row record;
BEGIN
  SELECT * INTO c
  FROM public.dv_accounting_commissions
  WHERE id = p_commission_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF upper(coalesce(c.status,'')) = 'PAID' THEN
    RAISE EXCEPTION 'Commission has already been paid';
  END IF;

  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = c.transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  SELECT * INTO a
  FROM public.dv_accounting_agents
  WHERE id = c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt := coalesce(c.gross_commission, t.gross_commission, 0);
  calc := public.dv_accounting_calculate_commission_fees(
    c.agent_id, c.transaction_id, gross_amt, coalesce(t.transaction_date, p_cheque_date)
  );
  agent_share := coalesce((calc->>'agent_share')::numeric, 0);
  transaction_fees := coalesce((calc->>'admin_fee')::numeric, 0)
                    + coalesce((calc->>'lead_fee')::numeric, 0);

  agent_hst_number := nullif(btrim(
    CASE WHEN coalesce(a.incorporated, false)
      THEN coalesce(a.prec_hst_number, a.hst_number)
      ELSE coalesce(a.hst_number, a.prec_hst_number)
    END
  ), '');
  IF agent_hst_number IS NOT NULL THEN
    -- Preserve the existing rule: agent HST is calculated before agent-charge deductions.
    agent_hst := round(greatest(agent_share - transaction_fees, 0) * agent_hst_rate / 100, 2);
  END IF;

  client_hst := CASE
    WHEN coalesce(t.hst_amount, 0) > 0 THEN round(t.hst_amount, 2)
    ELSE round(gross_amt * agent_hst_rate / 100, 2)
  END;
  brokerage_hst := greatest(client_hst - agent_hst, 0);

  available_before_charges := round(agent_share - transaction_fees + agent_hst + coalesce(p_adjustment, 0), 2);
  IF available_before_charges < -0.005 THEN
    RAISE EXCEPTION 'Transaction fees exceed the agent commission and HST available for payment. Review the commission calculation before issuing.';
  END IF;
  remaining_capacity := greatest(available_before_charges, 0);

  -- Oldest outstanding charges are recovered first. Charge rows are locked so that
  -- simultaneous direct payments and commission payouts cannot allocate the same balance.
  FOR charge_row IN
    SELECT ch.*
    FROM public.dv_accounting_commission_charges ch
    WHERE ch.agent_id = c.agent_id
      AND ch.charge_type IN (
        'DESK_FEE', 'RECURRING_FEE', 'ADD_ON_SERVICE',
        'GENERAL_EXPENSE', 'GENERAL_EXP', 'OTHER_FEE'
      )
      AND ch.status IN ('OPEN', 'PARTIAL')
      AND ch.applied_to_cheque_id IS NULL
    ORDER BY ch.created_at, ch.id
    FOR UPDATE OF ch
  LOOP
    SELECT coalesce(sum(p.amount), 0)
    INTO direct_paid
    FROM public.dv_accounting_agent_charge_payments p
    WHERE p.charge_id = charge_row.id;

    SELECT coalesce(sum(x.amount), 0)
    INTO previously_allocated
    FROM public.dv_accounting_agent_charge_commission_allocations x
    WHERE x.charge_id = charge_row.id;

    charge_total := round(
      coalesce(charge_row.amount, 0)
      + CASE WHEN charge_row.hst_applicable THEN coalesce(charge_row.hst_amount, 0) ELSE 0 END,
      2
    );
    charge_balance := greatest(round(
      charge_total - coalesce(charge_row.paid_amount, 0) - direct_paid - previously_allocated,
      2
    ), 0);
    total_outstanding := total_outstanding + charge_balance;

    amount_to_apply := least(charge_balance, remaining_capacity);
    IF amount_to_apply > 0.005 THEN
      amount_to_apply := round(amount_to_apply, 2);
      balance_after := greatest(round(charge_balance - amount_to_apply, 2), 0);
      allocations := allocations || jsonb_build_array(jsonb_build_object(
        'charge_id', charge_row.id,
        'charge_type', charge_row.charge_type,
        'amount', amount_to_apply,
        'balance_after', balance_after
      ));

      total_charge_deduction := total_charge_deduction + amount_to_apply;
      remaining_capacity := greatest(round(remaining_capacity - amount_to_apply, 2), 0);

      CASE charge_row.charge_type
        WHEN 'DESK_FEE' THEN desk_fees := desk_fees + amount_to_apply;
        WHEN 'RECURRING_FEE' THEN recurring_fees := recurring_fees + amount_to_apply;
        WHEN 'ADD_ON_SERVICE' THEN service_fees := service_fees + amount_to_apply;
        ELSE general_fees := general_fees + amount_to_apply;
      END CASE;
    END IF;
  END LOOP;

  total_charge_deduction := round(total_charge_deduction, 2);
  total_fees := round(transaction_fees + total_charge_deduction, 2);

  INSERT INTO public.dv_accounting_commission_cheques(
    company_id, agent_id, commission_id, cheque_number, cheque_date, gross_commission,
    agent_share, total_fees, adjustments, status, issued_at, notes,
    agent_hst_number, agent_hst_rate, agent_hst_amount, brokerage_hst_amount, client_hst_amount
  ) VALUES (
    t.company_id, c.agent_id, c.id, p_cheque_number, p_cheque_date, gross_amt,
    agent_share, total_fees, coalesce(p_adjustment, 0), 'ISSUED', now(), p_notes,
    agent_hst_number, agent_hst_rate, agent_hst, brokerage_hst, client_hst
  ) RETURNING id INTO cheque_id;

  FOR allocation_row IN
    SELECT *
    FROM jsonb_to_recordset(allocations)
      AS x(charge_id uuid, charge_type text, amount numeric, balance_after numeric)
  LOOP
    INSERT INTO public.dv_accounting_agent_charge_commission_allocations(
      company_id, agent_id, charge_id, commission_cheque_id, amount, recorded_by
    ) VALUES (
      t.company_id, c.agent_id, allocation_row.charge_id, cheque_id,
      round(allocation_row.amount, 2), auth.uid()
    );

    UPDATE public.dv_accounting_commission_charges
    SET status = CASE WHEN allocation_row.balance_after <= 0.005 THEN 'APPLIED' ELSE 'PARTIAL' END,
        applied_to_cheque_id = CASE WHEN allocation_row.balance_after <= 0.005 THEN cheque_id ELSE NULL END
    WHERE id = allocation_row.charge_id;
  END LOOP;

  INSERT INTO public.dv_accounting_commission_charges(
    commission_id, transaction_id, agent_id, charge_type, description,
    amount, source_rule_id, status, applied_to_cheque_id
  )
  SELECT c.id, c.transaction_id, c.agent_id, x.charge_type, x.description, x.amount,
    CASE WHEN x.charge_type IN ('ADMIN_FEE', 'LEAD_FEE') THEN (calc->>'fee_rule_id')::uuid ELSE NULL END,
    'APPLIED', cheque_id
  FROM jsonb_to_recordset(jsonb_build_array(
    jsonb_build_object('charge_type', 'ADMIN_FEE', 'description', 'Transaction admin fee',
      'amount', coalesce((calc->>'admin_fee')::numeric, 0)),
    jsonb_build_object('charge_type', 'LEAD_FEE', 'description', 'Transaction lead fee',
      'amount', coalesce((calc->>'lead_fee')::numeric, 0))
  )) AS x(charge_type text, description text, amount numeric)
  WHERE x.amount <> 0;

  UPDATE public.dv_accounting_commissions
  SET status = 'PAID', paid_date = p_cheque_date
  WHERE id = c.id;

  RETURN jsonb_build_object(
    'cheque_id', cheque_id,
    'commission_id', c.id,
    'agent_share', agent_share,
    'agent_hst_number', agent_hst_number,
    'agent_hst_rate', agent_hst_rate,
    'agent_hst_amount', agent_hst,
    'brokerage_hst_amount', brokerage_hst,
    'client_hst_amount', client_hst,
    'transaction_fees', transaction_fees,
    'desk_fees', round(desk_fees, 2),
    'recurring_fees', round(recurring_fees, 2),
    'service_fees', round(service_fees, 2),
    'general_expense', round(general_fees, 2),
    'total_outstanding_agent_charges', round(total_outstanding, 2),
    'total_agent_charge_deduction', total_charge_deduction,
    'remaining_agent_charge_balance', greatest(round(total_outstanding - total_charge_deduction, 2), 0),
    'total_fees', total_fees,
    'net_amount', greatest(round(agent_share - total_fees + coalesce(p_adjustment, 0) + agent_hst, 2), 0),
    'deducted_agent_charges', true,
    'calculation', calc
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_issue_commission_cheque(uuid, text, date, numeric, text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_issue_commission_cheque(uuid, text, date, numeric, text, boolean)
  TO authenticated;

-- Keep direct payments within the balance after HST, direct payments and prior commission deductions.
CREATE OR REPLACE FUNCTION public.dv_accounting_register_agent_charge_payment(
  p_charge_id uuid,
  p_payment_date date,
  p_amount numeric,
  p_method text DEFAULT 'EFT',
  p_reference text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  ch public.dv_accounting_commission_charges%ROWTYPE;
  ag public.dv_accounting_agents%ROWTYPE;
  direct_paid numeric(14,2) := 0;
  commission_allocated numeric(14,2) := 0;
  outstanding numeric(14,2) := 0;
  payment_id uuid;
  next_status text;
  last_cheque_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in before registering an agent payment.';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be greater than zero.';
  END IF;
  IF p_payment_date IS NULL THEN
    RAISE EXCEPTION 'Payment date is required.';
  END IF;

  SELECT * INTO ch
  FROM public.dv_accounting_commission_charges
  WHERE id = p_charge_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent charge not found.'; END IF;
  IF ch.status IN ('APPLIED', 'VOID', 'PAID') THEN
    RAISE EXCEPTION 'This charge is already settled, applied to commission, or voided.';
  END IF;

  SELECT * INTO ag
  FROM public.dv_accounting_agents
  WHERE id = ch.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found for this charge.'; END IF;

  SELECT coalesce(sum(p.amount), 0)
  INTO direct_paid
  FROM public.dv_accounting_agent_charge_payments p
  WHERE p.charge_id = ch.id;

  SELECT coalesce(sum(x.amount), 0)
  INTO commission_allocated
  FROM public.dv_accounting_agent_charge_commission_allocations x
  WHERE x.charge_id = ch.id;

  outstanding := greatest(round(
    coalesce(ch.amount, 0)
    + CASE WHEN ch.hst_applicable THEN coalesce(ch.hst_amount, 0) ELSE 0 END
    - coalesce(ch.paid_amount, 0)
    - direct_paid
    - commission_allocated,
    2
  ), 0);

  IF p_amount > outstanding + 0.005 THEN
    RAISE EXCEPTION 'Payment exceeds the outstanding charge balance of %.', outstanding;
  END IF;

  INSERT INTO public.dv_accounting_agent_charge_payments(
    company_id, agent_id, charge_id, payment_date, amount, method, reference, notes, recorded_by
  ) VALUES (
    ag.company_id, ag.id, ch.id, p_payment_date, round(p_amount, 2),
    coalesce(nullif(trim(p_method), ''), 'EFT'),
    nullif(trim(p_reference), ''), nullif(trim(p_notes), ''), auth.uid()
  ) RETURNING id INTO payment_id;

  SELECT coalesce(sum(p.amount), 0)
  INTO direct_paid
  FROM public.dv_accounting_agent_charge_payments p
  WHERE p.charge_id = ch.id;

  SELECT coalesce(sum(x.amount), 0)
  INTO commission_allocated
  FROM public.dv_accounting_agent_charge_commission_allocations x
  WHERE x.charge_id = ch.id;

  outstanding := greatest(round(
    coalesce(ch.amount, 0)
    + CASE WHEN ch.hst_applicable THEN coalesce(ch.hst_amount, 0) ELSE 0 END
    - coalesce(ch.paid_amount, 0)
    - direct_paid
    - commission_allocated,
    2
  ), 0);

  IF outstanding <= 0.005 THEN
    IF commission_allocated > 0 THEN
      next_status := 'APPLIED';
      SELECT x.commission_cheque_id INTO last_cheque_id
      FROM public.dv_accounting_agent_charge_commission_allocations x
      WHERE x.charge_id = ch.id
      ORDER BY x.created_at DESC, x.id DESC
      LIMIT 1;
    ELSE
      next_status := 'PAID';
      last_cheque_id := NULL;
    END IF;
  ELSE
    next_status := 'PARTIAL';
    last_cheque_id := NULL;
  END IF;

  UPDATE public.dv_accounting_commission_charges
  SET status = next_status, applied_to_cheque_id = last_cheque_id
  WHERE id = ch.id;

  RETURN jsonb_build_object(
    'payment_id', payment_id,
    'charge_id', ch.id,
    'paid_amount', direct_paid + coalesce(ch.paid_amount, 0),
    'commission_deducted_amount', commission_allocated,
    'outstanding_amount', outstanding,
    'status', next_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_register_agent_charge_payment(uuid, date, numeric, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_register_agent_charge_payment(uuid, date, numeric, text, text, text)
  TO authenticated;

-- A zero-value offset is an audit record, not a cash disbursement.
ALTER TABLE public.dv_accounting_commission_cheques
  DROP CONSTRAINT IF EXISTS dv_accounting_commission_cheques_payment_method_check;
ALTER TABLE public.dv_accounting_commission_cheques
  ADD CONSTRAINT dv_accounting_commission_cheques_payment_method_check
  CHECK (payment_method IN ('CHEQUE', 'EFT', 'OFFSET'));

DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$
  IF coalesce(NEW.net_amount,0)<=0 THEN
    RAISE EXCEPTION 'Cannot issue commission payment: cheque net amount must be greater than zero.';
  END IF;$old$;
  v_new text := $new$
  IF coalesce(NEW.net_amount,0)<-0.005 THEN
    RAISE EXCEPTION 'Cannot issue commission payment: cheque net amount cannot be negative.';
  END IF;
  IF coalesce(NEW.net_amount,0)<=0.005 THEN
    RETURN NEW;
  END IF;$new$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_post_commission_cheque_to_trust()'::regprocedure)
  INTO v_definition;
  IF position(v_old IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not locate the zero-value commission cheque guard; migration stopped.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END
$migration$;

NOTIFY pgrst, 'reload schema';
