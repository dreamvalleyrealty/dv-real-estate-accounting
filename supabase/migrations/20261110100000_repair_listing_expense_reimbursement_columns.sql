-- Repair/complete the listing-expense reimbursement schema used by Seller Settlements.
-- Safe to run even if the original reimbursement migration was already applied.

ALTER TABLE public.dv_listing_expenses
  ADD COLUMN IF NOT EXISTS operating_paid_confirmed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS operating_payment_date date,
  ADD COLUMN IF NOT EXISTS operating_payment_reference text,
  ADD COLUMN IF NOT EXISTS operating_payment_notes text,
  ADD COLUMN IF NOT EXISTS reimbursement_status text NOT NULL DEFAULT 'NOT_REIMBURSED',
  ADD COLUMN IF NOT EXISTS reimbursement_trust_transaction_id uuid,
  ADD COLUMN IF NOT EXISTS reimbursed_at timestamptz,
  ADD COLUMN IF NOT EXISTS reimbursed_by uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'dv_listing_expenses_reimbursement_status_check'
      AND conrelid = 'public.dv_listing_expenses'::regclass
  ) THEN
    ALTER TABLE public.dv_listing_expenses
      ADD CONSTRAINT dv_listing_expenses_reimbursement_status_check
      CHECK (reimbursement_status IN ('NOT_REIMBURSED','PENDING','COMPLETED'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS dv_listing_expenses_reimbursement_posting_unique
  ON public.dv_listing_expenses (reimbursement_trust_transaction_id)
  WHERE reimbursement_trust_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS dv_listing_expenses_reimbursement_status_idx
  ON public.dv_listing_expenses (listing_id, reimbursement_status);

COMMENT ON COLUMN public.dv_listing_expenses.operating_paid_confirmed IS
  'Admin confirmation that this listing expense was actually paid from the brokerage operating account.';
COMMENT ON COLUMN public.dv_listing_expenses.reimbursement_status IS
  'Trust reimbursement lifecycle; COMPLETED means a corresponding trust transaction has been posted.';
