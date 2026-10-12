-- 0025: agent recurring charge history and payment registration
CREATE TABLE IF NOT EXISTS public.dv_accounting_agent_charge_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.dv_accounting_companies(id) ON DELETE CASCADE,
  agent_id uuid NOT NULL REFERENCES public.dv_accounting_agents(id) ON DELETE RESTRICT,
  charge_id uuid NOT NULL REFERENCES public.dv_accounting_commission_charges(id) ON DELETE RESTRICT,
  payment_date date NOT NULL DEFAULT current_date,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  method text NOT NULL DEFAULT 'EFT',
  reference text,
  notes text,
  recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dv_agent_charge_payments_agent_date
  ON public.dv_accounting_agent_charge_payments(agent_id, payment_date DESC);
CREATE INDEX IF NOT EXISTS idx_dv_agent_charge_payments_charge
  ON public.dv_accounting_agent_charge_payments(charge_id);

-- Extend the existing charge status values to support direct payments and partial payments.
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.dv_accounting_commission_charges'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.dv_accounting_commission_charges DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE public.dv_accounting_commission_charges
  ADD CONSTRAINT dv_accounting_commission_charges_status_check
  CHECK (status IN ('OPEN','PARTIAL','PAID','APPLIED','VOID'));

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
AS $$
DECLARE
  ch public.dv_accounting_commission_charges%ROWTYPE;
  ag public.dv_accounting_agents%ROWTYPE;
  already_paid numeric(14,2);
  outstanding numeric(14,2);
  payment_id uuid;
  next_status text;
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
  IF ch.status IN ('APPLIED','VOID','PAID') THEN
    RAISE EXCEPTION 'This charge is already applied to commission, voided, or paid.';
  END IF;

  SELECT * INTO ag FROM public.dv_accounting_agents WHERE id = ch.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found for this charge.'; END IF;

  SELECT coalesce(sum(amount),0) INTO already_paid
  FROM public.dv_accounting_agent_charge_payments
  WHERE charge_id = ch.id;

  outstanding := round(coalesce(ch.amount,0) - already_paid, 2);
  IF p_amount > outstanding + 0.005 THEN
    RAISE EXCEPTION 'Payment exceeds the outstanding charge balance of %.', outstanding;
  END IF;

  INSERT INTO public.dv_accounting_agent_charge_payments(
    company_id, agent_id, charge_id, payment_date, amount, method, reference, notes, recorded_by
  ) VALUES (
    ag.company_id, ag.id, ch.id, p_payment_date, round(p_amount,2),
    coalesce(nullif(trim(p_method),''),'EFT'), nullif(trim(p_reference),''), nullif(trim(p_notes),''), auth.uid()
  ) RETURNING id INTO payment_id;

  SELECT coalesce(sum(amount),0) INTO already_paid
  FROM public.dv_accounting_agent_charge_payments
  WHERE charge_id = ch.id;

  next_status := CASE WHEN already_paid + 0.005 >= ch.amount THEN 'PAID' ELSE 'PARTIAL' END;
  UPDATE public.dv_accounting_commission_charges SET status = next_status WHERE id = ch.id;

  RETURN jsonb_build_object(
    'payment_id', payment_id,
    'charge_id', ch.id,
    'paid_amount', already_paid,
    'outstanding_amount', greatest(0, round(ch.amount - already_paid, 2)),
    'status', next_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_register_agent_charge_payment(uuid,date,numeric,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_register_agent_charge_payment(uuid,date,numeric,text,text,text) TO authenticated;
