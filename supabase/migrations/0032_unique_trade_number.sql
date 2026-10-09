-- 0032: enforce unique trade numbers.
-- A trade number identifies one transaction and cannot be reused.
CREATE UNIQUE INDEX IF NOT EXISTS dv_accounting_transactions_trade_number_uidx
ON public.dv_accounting_transactions (transaction_number)
WHERE transaction_number IS NOT NULL AND btrim(transaction_number) <> '';

COMMENT ON INDEX public.dv_accounting_transactions_trade_number_uidx IS
'Prevents multiple transactions from using the same non-blank trade number.';
