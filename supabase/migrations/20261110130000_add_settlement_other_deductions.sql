-- Store applicable seller/landlord charges separately in the settlement summary.
ALTER TABLE public.dv_accounting_seller_settlements
  ADD COLUMN IF NOT EXISTS other_deductions_amount numeric(14,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.dv_accounting_seller_settlements.other_deductions_amount IS
  'Applicable transaction/listing charges deducted from the trust deposit before calculating net seller or landlord proceeds.';
