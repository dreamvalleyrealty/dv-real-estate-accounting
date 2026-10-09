-- 0034: repair transaction commission schema
-- Ensures commission columns exist before trigger/function definitions.
-- Safe to run after partial application of 0031-0033.

CREATE TABLE IF NOT EXISTS public.dv_accounting_transaction_commissions (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.dv_accounting_transactions(id) on delete cascade,
  side text not null default 'LISTING' check(side in ('LISTING','BUYER')),
  calculation_type text not null default 'PERCENT' check(calculation_type in ('PERCENT','AMOUNT')),
  rate numeric(9,4) not null default 0,
  amount numeric(14,2) not null default 0,
  hst_rate numeric(6,3) not null default 13,
  hst_amount numeric(14,2) not null default 0,
  settlement_direction text not null default 'RECEIVABLE' check(settlement_direction in ('RECEIVABLE','PAYABLE')),
  brokerage_id uuid references public.dv_accounting_external_brokerages(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

ALTER TABLE public.dv_accounting_transaction_commissions
  ADD COLUMN IF NOT EXISTS side text,
  ADD COLUMN IF NOT EXISTS calculation_type text,
  ADD COLUMN IF NOT EXISTS rate numeric(9,4),
  ADD COLUMN IF NOT EXISTS amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS hst_rate numeric(6,3),
  ADD COLUMN IF NOT EXISTS hst_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS settlement_direction text,
  ADD COLUMN IF NOT EXISTS brokerage_id uuid,
  ADD COLUMN IF NOT EXISTS notes text;

UPDATE public.dv_accounting_transaction_commissions
SET
  side=COALESCE(side,'LISTING'),
  calculation_type=COALESCE(calculation_type,'PERCENT'),
  rate=COALESCE(rate,0),
  amount=COALESCE(amount,0),
  hst_rate=COALESCE(hst_rate,13),
  hst_amount=COALESCE(hst_amount,0),
  settlement_direction=COALESCE(settlement_direction,'RECEIVABLE')
WHERE side IS NULL
   OR calculation_type IS NULL
   OR rate IS NULL
   OR amount IS NULL
   OR hst_rate IS NULL
   OR hst_amount IS NULL
   OR settlement_direction IS NULL;

ALTER TABLE public.dv_accounting_transaction_commissions
  ALTER COLUMN side SET DEFAULT 'LISTING',
  ALTER COLUMN side SET NOT NULL,
  ALTER COLUMN calculation_type SET DEFAULT 'PERCENT',
  ALTER COLUMN calculation_type SET NOT NULL,
  ALTER COLUMN rate SET DEFAULT 0,
  ALTER COLUMN rate SET NOT NULL,
  ALTER COLUMN amount SET DEFAULT 0,
  ALTER COLUMN amount SET NOT NULL,
  ALTER COLUMN hst_rate SET DEFAULT 13,
  ALTER COLUMN hst_rate SET NOT NULL,
  ALTER COLUMN hst_amount SET DEFAULT 0,
  ALTER COLUMN hst_amount SET NOT NULL,
  ALTER COLUMN settlement_direction SET DEFAULT 'RECEIVABLE',
  ALTER COLUMN settlement_direction SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='dv_tx_commission_side_chk'
      AND conrelid='public.dv_accounting_transaction_commissions'::regclass
  ) THEN
    ALTER TABLE public.dv_accounting_transaction_commissions
      ADD CONSTRAINT dv_tx_commission_side_chk
      CHECK(side IN ('LISTING','BUYER'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='dv_tx_commission_calc_type_chk'
      AND conrelid='public.dv_accounting_transaction_commissions'::regclass
  ) THEN
    ALTER TABLE public.dv_accounting_transaction_commissions
      ADD CONSTRAINT dv_tx_commission_calc_type_chk
      CHECK(calculation_type IN ('PERCENT','AMOUNT'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='dv_tx_commission_direction_chk'
      AND conrelid='public.dv_accounting_transaction_commissions'::regclass
  ) THEN
    ALTER TABLE public.dv_accounting_transaction_commissions
      ADD CONSTRAINT dv_tx_commission_direction_chk
      CHECK(settlement_direction IN ('RECEIVABLE','PAYABLE'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.dv_accounting_sync_transaction_commission()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  sale_value numeric(14,2);
BEGIN
  SELECT COALESCE(sale_price,0) INTO sale_value
  FROM public.dv_accounting_transactions
  WHERE id=NEW.transaction_id;

  IF NEW.calculation_type='PERCENT' THEN
    NEW.amount:=round(sale_value*COALESCE(NEW.rate,0)/100,2);
  ELSE
    NEW.amount:=round(COALESCE(NEW.amount,0),2);
  END IF;

  NEW.hst_rate:=COALESCE(NEW.hst_rate,13);
  NEW.hst_amount:=round(NEW.amount*NEW.hst_rate/100,2);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_dv_accounting_sync_transaction_commission
ON public.dv_accounting_transaction_commissions;

CREATE TRIGGER trg_dv_accounting_sync_transaction_commission
BEFORE INSERT OR UPDATE OF calculation_type,rate,amount,hst_rate,transaction_id
ON public.dv_accounting_transaction_commissions
FOR EACH ROW
EXECUTE FUNCTION public.dv_accounting_sync_transaction_commission();

CREATE INDEX IF NOT EXISTS idx_dv_accounting_tx_commissions_transaction
  ON public.dv_accounting_transaction_commissions(transaction_id);
