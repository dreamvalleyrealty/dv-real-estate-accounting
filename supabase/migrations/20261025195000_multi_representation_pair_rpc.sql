-- Securely create/link the opposite-side submission without granting an agent
-- permission to create submissions for arbitrary agents.
CREATE OR REPLACE FUNCTION public.dv_accounting_upsert_multi_representation_pair(
  p_primary_submission_id uuid,
  p_opposite_agent_id uuid,
  p_opposite_payload jsonb,
  p_representation_side text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_primary public.dv_accounting_agent_trade_submissions%ROWTYPE;
  v_pair public.dv_accounting_agent_trade_submissions%ROWTYPE;
  v_my_agent_id uuid;
  v_agent_active boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication is required';
  END IF;

  SELECT * INTO v_primary
  FROM public.dv_accounting_agent_trade_submissions
  WHERE id = p_primary_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Primary trade submission was not found';
  END IF;

  v_my_agent_id := public.dv_accounting_my_agent_id();
  IF COALESCE(public.dv_accounting_is_trade_admin(), false) = false
     AND v_primary.agent_id IS DISTINCT FROM v_my_agent_id THEN
    RAISE EXCEPTION 'Only the assigned agent or a trade administrator can link the opposite representation';
  END IF;

  IF v_primary.representation_group_id IS NULL
     OR p_opposite_agent_id IS NULL
     OR v_primary.payload->>'opposite_side_dv_agent_id' IS DISTINCT FROM p_opposite_agent_id::text THEN
    RAISE EXCEPTION 'The primary submission does not authorize this opposite-side agent';
  END IF;

  IF v_primary.status NOT IN ('DRAFT', 'SUBMITTED', 'NEEDS_CHANGES') THEN
    RAISE EXCEPTION 'Only an active trade submission can be linked to the opposite-side draft';
  END IF;

  IF p_representation_side IS NULL
     OR p_representation_side NOT IN ('LANDLORD','TENANT','SELLER','BUYER')
     OR p_representation_side = v_primary.representation_side
     OR (v_primary.representation_side IN ('SELLER','BUYER') AND p_representation_side NOT IN ('SELLER','BUYER'))
     OR (v_primary.representation_side IN ('LANDLORD','TENANT') AND p_representation_side NOT IN ('LANDLORD','TENANT')) THEN
    RAISE EXCEPTION 'The opposite representation side is invalid';
  END IF;

  SELECT active INTO v_agent_active
  FROM public.dv_accounting_agents
  WHERE id = p_opposite_agent_id;
  IF NOT FOUND OR COALESCE(v_agent_active, false) = false THEN
    RAISE EXCEPTION 'Select an active Dream Valley agent for the opposite side';
  END IF;

  SELECT * INTO v_pair
  FROM public.dv_accounting_agent_trade_submissions
  WHERE representation_group_id = v_primary.representation_group_id
    AND representation_side = p_representation_side
    AND id <> v_primary.id
  ORDER BY created_at
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF v_pair.agent_id IS DISTINCT FROM p_opposite_agent_id THEN
      RAISE EXCEPTION 'An opposite-side submission already exists for a different agent. Ask an administrator to change the assignment.';
    END IF;
    IF v_pair.transaction_id IS NOT NULL
       AND v_pair.transaction_id IS DISTINCT FROM v_primary.transaction_id THEN
      RAISE EXCEPTION 'The opposite-side submission is linked to a different transaction';
    END IF;

    UPDATE public.dv_accounting_agent_trade_submissions
    SET transaction_id = v_primary.transaction_id,
        updated_at = now()
    WHERE id = v_pair.id;

    RETURN v_pair.id;
  END IF;

  INSERT INTO public.dv_accounting_agent_trade_submissions (
    agent_id, submitted_by, payload, listing_id, status, transaction_id,
    representation_group_id, representation_side, submitted_at
  )
  VALUES (
    p_opposite_agent_id,
    auth.uid(),
    COALESCE(p_opposite_payload, '{}'::jsonb),
    v_primary.listing_id,
    'DRAFT',
    v_primary.transaction_id,
    v_primary.representation_group_id,
    p_representation_side,
    NULL
  )
  RETURNING id INTO v_pair.id;

  RETURN v_pair.id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.dv_accounting_upsert_multi_representation_pair(uuid, uuid, jsonb, text) TO authenticated;

-- Keep both submissions attached to the same transaction even when an administrator
-- links the transaction through a separate workflow.
CREATE OR REPLACE FUNCTION public.dv_accounting_sync_multi_representation_transaction_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NEW.representation_group_id IS NULL OR NEW.transaction_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dv_accounting_agent_trade_submissions paired
    WHERE paired.representation_group_id = NEW.representation_group_id
      AND paired.id <> NEW.id
      AND paired.transaction_id IS NOT NULL
      AND paired.transaction_id IS DISTINCT FROM NEW.transaction_id
  ) THEN
    RAISE EXCEPTION 'Multi-representation submissions must share one transaction';
  END IF;

  UPDATE public.dv_accounting_agent_trade_submissions
  SET transaction_id = NEW.transaction_id,
      updated_at = now()
  WHERE representation_group_id = NEW.representation_group_id
    AND id <> NEW.id
    AND transaction_id IS NULL;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_multi_representation_transaction_link
  ON public.dv_accounting_agent_trade_submissions;
CREATE TRIGGER trg_sync_multi_representation_transaction_link
AFTER UPDATE OF transaction_id ON public.dv_accounting_agent_trade_submissions
FOR EACH ROW
WHEN (NEW.transaction_id IS DISTINCT FROM OLD.transaction_id)
EXECUTE FUNCTION public.dv_accounting_sync_multi_representation_transaction_link();

-- When the second representation submits, preserve the transaction's original number
-- and primary side instead of replacing them with the second submission's trade number/side.
DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$v_tx_no := coalesce(nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));$old$;
  v_new text := $new$IF s.representation_group_id IS NOT NULL AND s.transaction_id IS NOT NULL THEN
    SELECT nullif(trim(transaction_number), '') INTO v_tx_no
    FROM public.dv_accounting_transactions WHERE id = s.transaction_id;
  END IF;
  v_tx_no := coalesce(v_tx_no, nullif(trim(coalesce(p->>'transaction_number','')), ''), 'AG-' || upper(substr(replace(s.id::text,'-',''),1,10)));
  IF s.representation_group_id IS NOT NULL THEN
    p := jsonb_set(p, '{side}', to_jsonb(coalesce((
      SELECT nullif(trim(primary_side.payload->>'side'), '')
      FROM public.dv_accounting_agent_trade_submissions primary_side
      WHERE primary_side.representation_group_id = s.representation_group_id
        AND primary_side.id <> s.id
        AND nullif(trim(coalesce(primary_side.payload->>'opposite_side_dv_agent_id','')), '') IS NOT NULL
      ORDER BY primary_side.created_at
      LIMIT 1
    ), p->>'side')), true);
  END IF;$new$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_ensure_agent_trade_transaction(uuid)'::regprocedure)
    INTO v_definition;
  IF position(v_old in v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not find expected transaction-number assignment in dv_accounting_ensure_agent_trade_transaction; aborting migration.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END
$migration$;
