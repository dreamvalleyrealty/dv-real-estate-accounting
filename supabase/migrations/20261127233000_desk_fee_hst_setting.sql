-- Add a per-agent HST setting for recurring desk fees.
-- Existing agents default to HST applicable; the profile can disable it for approved exceptions.
ALTER TABLE public.dv_accounting_agent_fee_settings
  ADD COLUMN IF NOT EXISTS desk_fee_hst_applicable boolean NOT NULL DEFAULT true;

UPDATE public.dv_accounting_agent_service_subscriptions s
SET hst_applicable = COALESCE(fs.desk_fee_hst_applicable, true),
    hst_amount = 0
FROM public.dv_accounting_agent_fee_settings fs
WHERE fs.agent_id = s.agent_id
  AND s.service_type = 'DESK_FEE'
  AND s.active;

CREATE OR REPLACE FUNCTION public.dv_accounting_sync_agent_desk_fee_subscription(
  p_agent_id uuid,
  p_start_date date DEFAULT CURRENT_DATE
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  a public.dv_accounting_agents%ROWTYPE;
  fs public.dv_accounting_agent_fee_settings%ROWTYPE;
  plan public.dv_accounting_fee_plans%ROWTYPE;
  sub public.dv_accounting_agent_service_subscriptions%ROWTYPE;
  sid uuid;
  fee numeric(14,2);
  free_months integer := 0;
  effective_start date;
  billing_start date;
  first_bill_month date;
  candidate_month date;
  last_period_end date;
  next_bill_date date;
  charge_hst boolean := true;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT (
       public.dv_accounting_has_permission('agents.edit')
       OR public.dv_accounting_has_permission('fees.manage')
     ) THEN
    RAISE EXCEPTION 'Not authorized to synchronize agent desk-fee billing'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO a FROM public.dv_accounting_agents WHERE id = p_agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  SELECT * INTO fs FROM public.dv_accounting_agent_fee_settings WHERE agent_id = p_agent_id;
  IF fs.fee_plan_id IS NOT NULL THEN
    SELECT * INTO plan FROM public.dv_accounting_fee_plans WHERE id = fs.fee_plan_id;
  END IF;

  SELECT * INTO sub
  FROM public.dv_accounting_agent_service_subscriptions
  WHERE agent_id = p_agent_id AND service_type = 'DESK_FEE' AND active
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  fee := greatest(0, coalesce(fs.desk_fee_override, plan.desk_fee, sub.amount, 0));
  free_months := greatest(0, coalesce(fs.desk_fee_free_months, 0));
  charge_hst := coalesce(fs.desk_fee_hst_applicable, true);
  effective_start := coalesce(a.start_date, p_start_date, CURRENT_DATE);

  billing_start := coalesce(
    fs.desk_fee_billing_start_date,
    date_trunc('month', CURRENT_DATE + interval '1 month')::date
  );
  first_bill_month := (
    date_trunc('month', billing_start)::date + make_interval(months => free_months)
  )::date;

  IF fee <= 0 THEN
    UPDATE public.dv_accounting_agent_service_subscriptions
    SET active = false, end_date = coalesce(end_date, CURRENT_DATE)
    WHERE agent_id = p_agent_id AND service_type = 'DESK_FEE' AND active;
    RETURN NULL;
  END IF;

  IF sub.id IS NOT NULL THEN
    SELECT max(service_period_end) INTO last_period_end
    FROM public.dv_accounting_commission_charges
    WHERE source_subscription_id = sub.id AND charge_type = 'DESK_FEE';

    candidate_month := greatest(
      first_bill_month,
      coalesce(date_trunc('month', last_period_end + 1)::date, first_bill_month),
      CASE WHEN sub.next_charge_date >= billing_start
        THEN date_trunc('month', sub.next_charge_date)::date
        ELSE first_bill_month
      END
    );
    next_bill_date := (candidate_month + interval '1 month - 1 day')::date;

    UPDATE public.dv_accounting_agent_service_subscriptions
    SET amount = fee,
        hst_applicable = charge_hst,
        hst_amount = 0,
        frequency = 'MONTHLY',
        start_date = effective_start,
        next_charge_date = next_bill_date,
        active = true
    WHERE id = sub.id
    RETURNING id INTO sid;
    RETURN sid;
  END IF;

  next_bill_date := (first_bill_month + interval '1 month - 1 day')::date;
  INSERT INTO public.dv_accounting_agent_service_subscriptions(
    company_id, agent_id, service_type, name, amount, hst_amount,
    hst_applicable, frequency, start_date, next_charge_date, active, notes
  ) VALUES (
    a.company_id, a.id, 'DESK_FEE', 'Desk Fee', fee, 0,
    charge_hst, 'MONTHLY', effective_start, next_bill_date, true,
    'Monthly desk fee billing starts from the separately configured billing start date'
  )
  RETURNING id INTO sid;
  RETURN sid;
END;
$func$;

REVOKE ALL ON FUNCTION public.dv_accounting_sync_agent_desk_fee_subscription(uuid, date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dv_accounting_sync_agent_desk_fee_subscription(uuid, date)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
