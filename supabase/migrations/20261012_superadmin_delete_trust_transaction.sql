-- Super Admin-only deletion for posted trust banking activity.
-- Refuses deletion if the corresponding bank entry is missing, ambiguous, or reconciled.
CREATE OR REPLACE FUNCTION public.dv_accounting_delete_trust_transaction(p_trust_transaction_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tt public.dv_accounting_trust_transactions%ROWTYPE;
  v_bank_id uuid;
  v_bank_count integer;
  v_role text;
BEGIN
  v_role := upper(regexp_replace(coalesce(
    auth.jwt() -> 'app_metadata' ->> 'role',
    auth.jwt() -> 'app_metadata' ->> 'user_role',
    auth.jwt() -> 'user_metadata' ->> 'role',
    auth.jwt() -> 'user_metadata' ->> 'user_role',
    ''
  ), '[^A-Za-z]', '', 'g'));

  IF v_role NOT IN ('SUPERADMIN', 'SUPERADMINISTRATOR') THEN
    BEGIN
      SELECT upper(regexp_replace(coalesce(role, ''), '[^A-Za-z]', '', 'g'))
        INTO v_role
      FROM public.dv_accounting_user_profiles
      WHERE user_id = auth.uid()
      LIMIT 1;
    EXCEPTION WHEN undefined_table OR undefined_column THEN
      v_role := '';
    END;
  END IF;

  IF coalesce(v_role, '') NOT IN ('SUPERADMIN', 'SUPERADMINISTRATOR') THEN
    RAISE EXCEPTION 'Only a Super Admin can delete banking transactions.';
  END IF;

  SELECT * INTO v_tt
  FROM public.dv_accounting_trust_transactions
  WHERE id = p_trust_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trust transaction was not found.';
  END IF;

  IF upper(coalesce(v_tt.status, '')) <> 'POSTED' THEN
    RAISE EXCEPTION 'Only posted trust transactions can be deleted through this workflow.';
  END IF;

  SELECT count(*) INTO v_bank_count
  FROM public.dv_accounting_bank_transactions bt
  WHERE bt.bank_account_id = v_tt.bank_account_id
    AND bt.transaction_date = v_tt.ledger_date
    AND abs(coalesce(bt.amount, 0)) = abs(coalesce(v_tt.amount, 0))
    AND coalesce(bt.description, '') = coalesce(v_tt.description, '')
    AND coalesce(bt.reference, '') = coalesce(v_tt.reference, '');

  IF v_bank_count <> 1 THEN
    RAISE EXCEPTION 'Could not identify exactly one matching bank entry. No records were deleted.';
  END IF;

  SELECT bt.id INTO v_bank_id
  FROM public.dv_accounting_bank_transactions bt
  WHERE bt.bank_account_id = v_tt.bank_account_id
    AND bt.transaction_date = v_tt.ledger_date
    AND abs(coalesce(bt.amount, 0)) = abs(coalesce(v_tt.amount, 0))
    AND coalesce(bt.description, '') = coalesce(v_tt.description, '')
    AND coalesce(bt.reference, '') = coalesce(v_tt.reference, '')
  LIMIT 1;

  IF EXISTS (SELECT 1 FROM public.dv_accounting_bank_transactions
             WHERE id = v_bank_id AND coalesce(reconciled, false) = true) THEN
    RAISE EXCEPTION 'This banking transaction has been reconciled and cannot be deleted. Correct it through an approved accounting adjustment.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.dv_accounting_reconciliations rec
    WHERE rec.bank_account_id = v_tt.bank_account_id
      AND rec.period_end >= v_tt.ledger_date
      AND upper(coalesce(rec.status, '')) = 'RECONCILED'
  ) THEN
    RAISE EXCEPTION 'A completed reconciliation covers this transaction date. Reopen/correct the reconciliation before deleting this entry.';
  END IF;

  DELETE FROM public.dv_accounting_trust_liabilities
  WHERE trust_transaction_id = v_tt.id;

  DELETE FROM public.dv_accounting_bank_transactions
  WHERE id = v_bank_id;

  DELETE FROM public.dv_accounting_trust_transactions
  WHERE id = v_tt.id;
END;
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_delete_trust_transaction(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dv_accounting_delete_trust_transaction(uuid) TO authenticated;
