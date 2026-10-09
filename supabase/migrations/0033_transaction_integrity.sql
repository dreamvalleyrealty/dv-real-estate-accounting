-- 0033: transaction integrity and automatic commission/HST calculation
-- Keeps the six-tab transaction workflow consistent even when commission rows are edited/imported outside the UI.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='dv_accounting_transactions_agent_id_fkey'
      AND conrelid='public.dv_accounting_transactions'::regclass
  ) THEN
    ALTER TABLE public.dv_accounting_transactions
      ADD CONSTRAINT dv_accounting_transactions_agent_id_fkey
      FOREIGN KEY (agent_id) REFERENCES public.dv_accounting_agents(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_dv_accounting_transactions_agent_id
  ON public.dv_accounting_transactions(agent_id);

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

CREATE OR REPLACE FUNCTION public.dv_accounting_resync_transaction_commissions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.dv_accounting_transaction_commissions
  SET amount=amount
  WHERE transaction_id=NEW.id;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_dv_accounting_resync_transaction_commissions
ON public.dv_accounting_transactions;

CREATE TRIGGER trg_dv_accounting_resync_transaction_commissions
AFTER UPDATE OF sale_price
ON public.dv_accounting_transactions
FOR EACH ROW
WHEN (OLD.sale_price IS DISTINCT FROM NEW.sale_price)
EXECUTE FUNCTION public.dv_accounting_resync_transaction_commissions();

-- Recalculate existing commission rows after the trigger is installed.
UPDATE public.dv_accounting_transaction_commissions
SET amount=amount;
