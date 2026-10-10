-- 0047: Super Admin-only destructive paid commission reset for correction and redo.
-- Deletes the paid commission, its cheque(s), correction audit rows, and commission charges,
-- then returns the linked transaction to FINALIZED so it can be recalculated and closed again.
CREATE OR REPLACE FUNCTION public.dv_accounting_delete_paid_commission(p_commission_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  v_role text;
  v_cheques integer := 0;
  v_charges integer := 0;
  v_corrections integer := 0;
BEGIN
  SELECT upper(coalesce(role,'')) INTO v_role
  FROM public.dv_accounting_user_profiles
  WHERE user_id=auth.uid()
  LIMIT 1;

  IF coalesce(v_role,'') <> 'SUPERADMIN' THEN
    RAISE EXCEPTION 'Super Admin permission required to delete a paid commission';
  END IF;

  SELECT * INTO c
  FROM public.dv_accounting_commissions
  WHERE id=p_commission_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF upper(coalesce(c.status,'')) <> 'PAID' THEN
    RAISE EXCEPTION 'Only a paid commission can be deleted with Delete & Redo';
  END IF;

  SELECT * INTO t
  FROM public.dv_accounting_transactions
  WHERE id=c.transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Linked transaction not found'; END IF;

  -- Remove correction records first because they intentionally protect the commission
  -- from ordinary DELETE operations.
  DELETE FROM public.dv_accounting_commission_corrections
  WHERE commission_id=c.id;
  GET DIAGNOSTICS v_corrections = ROW_COUNT;

  -- Charges belonging to this commission are disposable. Existing recurring/service
  -- charges that were applied to its cheque are reopened so they can be applied again.
  UPDATE public.dv_accounting_commission_charges
  SET status='OPEN', applied_to_cheque_id=NULL
  WHERE applied_to_cheque_id IN (
    SELECT id FROM public.dv_accounting_commission_cheques WHERE commission_id=c.id
  );

  DELETE FROM public.dv_accounting_commission_charges
  WHERE commission_id=c.id;
  GET DIAGNOSTICS v_charges = ROW_COUNT;

  DELETE FROM public.dv_accounting_commission_cheques
  WHERE commission_id=c.id;
  GET DIAGNOSTICS v_cheques = ROW_COUNT;

  DELETE FROM public.dv_accounting_commissions
  WHERE id=c.id;

  -- Reopen the accounting workflow at Finalized. The existing approved commission
  -- amount remains available, and closing it again recreates a fresh UNPAID commission.
  UPDATE public.dv_accounting_transactions
  SET status='FINALIZED',
      closed_at=NULL,
      closed_by=NULL,
      commission_id=NULL,
      commission_payroll_status='NOT_READY'
  WHERE id=t.id;

  RETURN jsonb_build_object(
    'ok',true,
    'commission_id',c.id,
    'transaction_id',t.id,
    'deleted_cheques',v_cheques,
    'deleted_charges',v_charges,
    'deleted_corrections',v_corrections,
    'transaction_status','FINALIZED'
  );
END $$;

REVOKE ALL ON FUNCTION public.dv_accounting_delete_paid_commission(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_delete_paid_commission(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
