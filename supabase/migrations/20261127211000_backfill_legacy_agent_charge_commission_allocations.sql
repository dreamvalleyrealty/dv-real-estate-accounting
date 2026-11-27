-- Preserve the legacy commission deductions in the new allocation history.
-- Existing APPLIED rows already point to the commission cheque that settled them.
WITH direct_payments AS (
  SELECT charge_id, sum(amount) AS paid_amount
  FROM public.dv_accounting_agent_charge_payments
  GROUP BY charge_id
)
INSERT INTO public.dv_accounting_agent_charge_commission_allocations (
  company_id, agent_id, charge_id, commission_cheque_id, amount, recorded_by, created_at
)
SELECT
  q.company_id,
  ch.agent_id,
  ch.id,
  ch.applied_to_cheque_id,
  greatest(round(
    coalesce(ch.amount, 0)
    + CASE WHEN ch.hst_applicable THEN coalesce(ch.hst_amount, 0) ELSE 0 END
    - coalesce(ch.paid_amount, 0)
    - coalesce(dp.paid_amount, 0),
    2
  ), 0),
  NULL,
  coalesce(q.issued_at, ch.created_at, now())
FROM public.dv_accounting_commission_charges ch
JOIN public.dv_accounting_commission_cheques q
  ON q.id = ch.applied_to_cheque_id
LEFT JOIN direct_payments dp
  ON dp.charge_id = ch.id
WHERE ch.status = 'APPLIED'
  AND ch.applied_to_cheque_id IS NOT NULL
  AND ch.charge_type IN (
    'DESK_FEE', 'RECURRING_FEE', 'ADD_ON_SERVICE',
    'GENERAL_EXPENSE', 'GENERAL_EXP', 'OTHER_FEE'
  )
  AND greatest(round(
    coalesce(ch.amount, 0)
    + CASE WHEN ch.hst_applicable THEN coalesce(ch.hst_amount, 0) ELSE 0 END
    - coalesce(ch.paid_amount, 0)
    - coalesce(dp.paid_amount, 0),
    2
  ), 0) > 0.005
ON CONFLICT (charge_id, commission_cheque_id) DO NOTHING;
