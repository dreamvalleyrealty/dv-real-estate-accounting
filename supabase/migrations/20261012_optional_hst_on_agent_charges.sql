-- 0026: optional HST on recurring rules and agent service charges
ALTER TABLE public.dv_accounting_recurring_fee_rules
  ADD COLUMN IF NOT EXISTS hst_applicable boolean NOT NULL DEFAULT false;
ALTER TABLE public.dv_accounting_agent_service_subscriptions
  ADD COLUMN IF NOT EXISTS hst_applicable boolean NOT NULL DEFAULT false;
ALTER TABLE public.dv_accounting_commission_charges
  ADD COLUMN IF NOT EXISTS hst_applicable boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS base_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS hst_amount numeric(14,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.dv_accounting_apply_charge_hst()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_base numeric(14,2);
  v_hst_enabled boolean := coalesce(NEW.hst_applicable,false);
  v_hst numeric(14,2) := 0;
  v_rule public.dv_accounting_recurring_fee_rules%ROWTYPE;
  v_service public.dv_accounting_agent_service_subscriptions%ROWTYPE;
BEGIN
  -- Older billing RPCs do not pass the HST flag, so resolve it from the
  -- originating recurring rule or service subscription where possible.
  IF NEW.charge_type = 'RECURRING_FEE' AND NEW.agent_id IS NOT NULL THEN
    SELECT * INTO v_rule
    FROM public.dv_accounting_recurring_fee_rules r
    WHERE r.agent_id = NEW.agent_id
      AND coalesce(r.description,r.name) = NEW.description
    ORDER BY r.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      v_hst_enabled := coalesce(v_rule.hst_applicable,false);
    END IF;
  ELSIF NEW.charge_type IN ('DESK_FEE','ADD_ON_SERVICE') AND NEW.agent_id IS NOT NULL THEN
    SELECT * INTO v_service
    FROM public.dv_accounting_agent_service_subscriptions s
    WHERE s.agent_id = NEW.agent_id AND s.name = NEW.description
    ORDER BY s.created_at DESC
    LIMIT 1;
    IF FOUND THEN
      v_hst_enabled := coalesce(v_service.hst_applicable,false);
    END IF;
  END IF;

  -- Do not reapply HST if a charge already has a stored base amount.
  IF NEW.base_amount IS NULL THEN
    v_base := round(coalesce(NEW.amount,0),2);
    v_hst := CASE WHEN v_hst_enabled THEN round(v_base * 0.13,2) ELSE 0 END;
    NEW.base_amount := v_base;
    NEW.hst_applicable := v_hst_enabled;
    NEW.hst_amount := v_hst;
    NEW.amount := v_base + v_hst;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_dv_accounting_apply_charge_hst
  ON public.dv_accounting_commission_charges;
CREATE TRIGGER trg_dv_accounting_apply_charge_hst
BEFORE INSERT ON public.dv_accounting_commission_charges
FOR EACH ROW EXECUTE FUNCTION public.dv_accounting_apply_charge_hst();

-- Existing charges are left unchanged; no retroactive HST is added.
