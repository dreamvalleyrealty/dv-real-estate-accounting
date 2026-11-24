-- Separate deal lifecycle from accounting transaction status.
ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS deal_status text NOT NULL DEFAULT 'DRAFT',
  ADD COLUMN IF NOT EXISTS deal_status_reason text,
  ADD COLUMN IF NOT EXISTS deal_status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS deal_status_changed_by uuid;

ALTER TABLE public.dv_accounting_agent_trade_submissions
  ADD COLUMN IF NOT EXISTS deal_status text NOT NULL DEFAULT 'DRAFT';

UPDATE public.dv_accounting_transactions
SET deal_status = CASE
  WHEN upper(coalesce(status,'')) = 'CLOSED' THEN 'CLOSED'
  WHEN upper(coalesce(status,'')) = 'DFT' THEN 'DFT'
  WHEN firm_date IS NOT NULL THEN 'FIRM'
  WHEN offer_date IS NOT NULL THEN 'CONDITIONAL'
  ELSE 'DRAFT'
END
WHERE deal_status = 'DRAFT';

UPDATE public.dv_accounting_agent_trade_submissions s
SET deal_status = t.deal_status
FROM public.dv_accounting_transactions t
WHERE t.id = s.transaction_id;

ALTER TABLE public.dv_accounting_transactions
  DROP CONSTRAINT IF EXISTS dv_accounting_transactions_deal_status_check;
ALTER TABLE public.dv_accounting_transactions
  ADD CONSTRAINT dv_accounting_transactions_deal_status_check
  CHECK (deal_status IN ('DRAFT','CONDITIONAL','FIRM','TERMINATED','DFT','CLOSED'));

ALTER TABLE public.dv_accounting_agent_trade_submissions
  DROP CONSTRAINT IF EXISTS dv_accounting_agent_trade_submissions_deal_status_check;
ALTER TABLE public.dv_accounting_agent_trade_submissions
  ADD CONSTRAINT dv_accounting_agent_trade_submissions_deal_status_check
  CHECK (deal_status IN ('DRAFT','CONDITIONAL','FIRM','TERMINATED','DFT','CLOSED'));

CREATE TABLE IF NOT EXISTS public.dv_accounting_deal_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES public.dv_accounting_transactions(id) ON DELETE RESTRICT,
  previous_status text NOT NULL,
  new_status text NOT NULL,
  reason text,
  changed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dv_deal_status_history_transaction
  ON public.dv_accounting_deal_status_history(transaction_id, changed_at DESC);

ALTER TABLE public.dv_accounting_deal_status_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dv_accounting_deal_status_history FROM anon, authenticated;
GRANT SELECT ON public.dv_accounting_deal_status_history TO authenticated;
DROP POLICY IF EXISTS "Trade admins can view deal status history" ON public.dv_accounting_deal_status_history;
CREATE POLICY "Trade admins can view deal status history"
  ON public.dv_accounting_deal_status_history
  FOR SELECT TO authenticated
  USING (public.dv_accounting_is_trade_admin());

CREATE OR REPLACE FUNCTION public.dv_accounting_set_deal_status(
  p_transaction_id uuid,
  p_deal_status text,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  v_previous text;
  v_next text := upper(trim(coalesce(p_deal_status,'')));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to change a deal status';
  END IF;
  IF NOT public.dv_accounting_is_trade_admin() THEN
    RAISE EXCEPTION 'Only an administrator with trade management permission can change deal status';
  END IF;
  IF v_next NOT IN ('CONDITIONAL','FIRM','TERMINATED') THEN
    RAISE EXCEPTION 'Select Conditional, Firm, or Terminated';
  END IF;

  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  v_previous := upper(coalesce(nullif(t.deal_status,''), 'DRAFT'));
  IF v_previous = v_next THEN
    RETURN jsonb_build_object('ok',true,'transaction_id',t.id,'deal_status',v_next,'unchanged',true);
  END IF;

  IF v_previous IN ('TERMINATED','DFT','CLOSED') THEN
    RAISE EXCEPTION 'This deal has a final outcome and its status cannot be changed';
  END IF;
  IF v_next = 'CONDITIONAL' AND v_previous <> 'DRAFT' THEN
    RAISE EXCEPTION 'Only a draft deal can be moved to Conditional';
  END IF;
  IF v_next = 'FIRM' AND v_previous <> 'CONDITIONAL' THEN
    RAISE EXCEPTION 'A deal must be Conditional before it can become Firm';
  END IF;
  IF v_next = 'TERMINATED' AND v_previous <> 'CONDITIONAL' THEN
    RAISE EXCEPTION 'Only a Conditional deal can be terminated. Use DFT after a deal becomes Firm';
  END IF;

  UPDATE public.dv_accounting_transactions
  SET deal_status = v_next,
      deal_status_reason = nullif(trim(coalesce(p_reason,'')), ''),
      deal_status_changed_at = now(),
      deal_status_changed_by = auth.uid(),
      firm_date = CASE WHEN v_next = 'FIRM' THEN coalesce(firm_date, current_date) ELSE firm_date END
  WHERE id = t.id;

  UPDATE public.dv_accounting_agent_trade_submissions
  SET deal_status = v_next,
      updated_at = now()
  WHERE transaction_id = t.id;

  INSERT INTO public.dv_accounting_deal_status_history
    (transaction_id, previous_status, new_status, reason, changed_by)
  VALUES
    (t.id, v_previous, v_next, nullif(trim(coalesce(p_reason,'')), ''), auth.uid());

  RETURN jsonb_build_object('ok',true,'transaction_id',t.id,'previous_status',v_previous,'deal_status',v_next);
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_set_deal_status(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_set_deal_status(uuid,text,text) TO authenticated, service_role;

-- Restrict the legacy DFT/refund routine behind an administrator-only wrapper.
ALTER FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean)
  RENAME TO dv_accounting_mark_transaction_dft_internal;
REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft_internal(uuid,uuid,date,text,text,text,boolean)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_mark_transaction_dft(
  p_transaction_id uuid,
  p_refund_bank_account_id uuid,
  p_refund_date date,
  p_refund_method text,
  p_refund_reference text,
  p_authority_reference text,
  p_release_authorized boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  t public.dv_accounting_transactions%ROWTYPE;
  v_previous text;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to mark a deal DFT';
  END IF;
  IF NOT public.dv_accounting_is_trade_admin() THEN
    RAISE EXCEPTION 'Only an administrator with trade management permission can mark a deal DFT';
  END IF;

  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  v_previous := upper(coalesce(nullif(t.deal_status,''), 'DRAFT'));
  IF v_previous <> 'FIRM' THEN
    RAISE EXCEPTION 'DFT is only available after the deal has become Firm';
  END IF;

  v_result := public.dv_accounting_mark_transaction_dft_internal(
    p_transaction_id,p_refund_bank_account_id,p_refund_date,p_refund_method,
    p_refund_reference,p_authority_reference,p_release_authorized
  );

  UPDATE public.dv_accounting_transactions
  SET deal_status = 'DFT',
      deal_status_changed_at = now(),
      deal_status_changed_by = auth.uid()
  WHERE id = p_transaction_id;

  UPDATE public.dv_accounting_agent_trade_submissions
  SET deal_status = 'DFT',
      updated_at = now()
  WHERE transaction_id = p_transaction_id;

  INSERT INTO public.dv_accounting_deal_status_history
    (transaction_id, previous_status, new_status, reason, changed_by)
  VALUES
    (p_transaction_id, 'FIRM', 'DFT', nullif(trim(coalesce(p_authority_reference,'')), ''), auth.uid());

  RETURN coalesce(v_result,'{}'::jsonb) || jsonb_build_object('deal_status','DFT');
END;
$function$;

REVOKE ALL ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_mark_transaction_dft(uuid,uuid,date,text,text,text,boolean)
  TO authenticated, service_role;

COMMENT ON COLUMN public.dv_accounting_transactions.deal_status IS
  'Deal lifecycle, separate from accounting status. DFT is set only through the protected DFT workflow.';
COMMENT ON COLUMN public.dv_accounting_agent_trade_submissions.deal_status IS
  'Deal lifecycle mirrored from the linked transaction; submission review status remains in status.';
