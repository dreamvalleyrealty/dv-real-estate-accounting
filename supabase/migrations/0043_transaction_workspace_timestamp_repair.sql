-- 0043: harden transaction workspace timestamps for existing databases
-- Some older installations created the transaction workspace tables before
-- their timestamp columns were introduced. Add them idempotently so inserts,
-- updates, triggers and PostgREST queries remain compatible.

ALTER TABLE public.dv_accounting_transactions
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transactions
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transactions
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_people
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_people
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_people
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_conditions
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_conditions
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_conditions
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_outside_brokers
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_outside_brokers
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_outside_brokers
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_trust
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_trust
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_trust
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_commissions
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_commissions
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_commissions
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.dv_accounting_transaction_agent_info
  ADD COLUMN IF NOT EXISTS created_at timestamptz;

UPDATE public.dv_accounting_transaction_agent_info
SET created_at = COALESCE(created_at, now())
WHERE created_at IS NULL;

ALTER TABLE public.dv_accounting_transaction_agent_info
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

NOTIFY pgrst, 'reload schema';
