-- Post an issued seller cheque/EFT to Real Estate Trust and reduce the matching trust liability.
-- Idempotent: retrying the same saved settlement will not post a second disbursement.
CREATE OR REPLACE FUNCTION public.dv_accounting_post_seller_settlement_payment(
  p_settlement_id uuid
)
RETURNS public.dv_accounting_seller_settlements
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v public.dv_accounting_seller_settlements%ROWTYPE;
  v_trust_client_name text;
  v_existing_count integer;
BEGIN
  SELECT *
    INTO v
  FROM public.dv_accounting_seller_settlements
  WHERE id = p_settlement_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Seller settlement was not found.';
  END IF;

  IF coalesce(v.seller_paid_amount, 0) < coalesce(v.seller_proceeds_amount, 0)
     OR coalesce(v.seller_proceeds_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'Save the full seller payment amount before posting the trust disbursement.';
  END IF;

  IF coalesce(nullif(trim(v.seller_payment_reference), ''), '') = ''
     OR v.seller_payment_date IS NULL THEN
    RAISE EXCEPTION 'Seller cheque/EFT reference and payment date are required.';
  END IF;

  IF v.real_estate_trust_account_id IS NULL THEN
    RAISE EXCEPTION 'Select a Real Estate Trust account before posting the seller payment.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.dv_accounting_bank_accounts ba
    WHERE ba.id = v.real_estate_trust_account_id
      AND ba.company_id = v.company_id
      AND upper(replace(replace(coalesce(ba.account_type, ''), '_', ''), ' ', '')) = 'REALESTATETRUST'
  ) THEN
    RAISE EXCEPTION 'The selected account is not a Real Estate Trust account for this company.';
  END IF;

  -- Use the client identity on the original deposit liability, not the cheque payee.
  SELECT l.client_name
    INTO v_trust_client_name
  FROM public.dv_accounting_trust_liabilities l
  WHERE l.company_id = v.company_id
    AND l.trust_account_type = 'REAL_ESTATE_TRUST'
    AND l.matter = v.matter
    AND l.direction = 'RECEIVABLE'
    AND l.amount > 0
  ORDER BY l.created_at
  LIMIT 1;

  IF coalesce(nullif(trim(v_trust_client_name), ''), '') = '' THEN
    RAISE EXCEPTION 'Cannot identify the original trust deposit client for trade %.', v.matter;
  END IF;

  -- A matching posted payment makes this function safe to retry after a network timeout.
  SELECT count(*)
    INTO v_existing_count
  FROM public.dv_accounting_trust_transactions tt
  WHERE tt.bank_account_id = v.real_estate_trust_account_id
    AND tt.transaction_id = v.transaction_id
    AND tt.trust_account_type = 'REAL_ESTATE_TRUST'
    AND tt.direction = 'DISBURSEMENT'
    AND tt.matter = v.matter
    AND tt.reference = v.seller_payment_reference
    AND tt.amount = v.seller_proceeds_amount
    AND upper(coalesce(tt.status, '')) = 'POSTED';

  IF v_existing_count = 0 THEN
    PERFORM public.dv_accounting_post_trust_transaction(
      v.company_id,
      v.real_estate_trust_account_id,
      v.transaction_id,
      v.seller_payment_date,
      'REAL_ESTATE_TRUST',
      'DISBURSEMENT',
      v_trust_client_name,
      v.matter,
      'Seller cheque/EFT payment to ' || v.seller_client_name || ' - ' || v.matter,
      v.seller_proceeds_amount,
      v.seller_payment_reference
    );
  END IF;

  SELECT *
    INTO v
  FROM public.dv_accounting_seller_settlements
  WHERE id = p_settlement_id;

  RETURN v;
END;
$$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_post_seller_settlement_payment(uuid) TO authenticated;
