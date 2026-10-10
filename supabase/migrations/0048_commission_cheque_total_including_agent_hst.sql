-- 0048: Make the persisted commission cheque net_amount exactly equal to the
-- amount payable to the agent, including agent HST where applicable.
--
-- Formula:
-- agent share - total fees + adjustments + agent HST = cheque amount
--
-- This keeps Transaction > Agent Info, Commission Payroll and the issued
-- commission cheque on the same payable amount.

ALTER TABLE public.dv_accounting_commission_cheques
  DROP COLUMN IF EXISTS net_amount;

ALTER TABLE public.dv_accounting_commission_cheques
  ADD COLUMN net_amount numeric(14,2)
  GENERATED ALWAYS AS (
    agent_share
    - total_fees
    + adjustments
    + COALESCE(agent_hst_amount, 0)
  ) STORED;

NOTIFY pgrst, 'reload schema';
