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
  IF NOT public.dv_accounting_is_trade_admin()
     AND v_primary.agent_id IS DISTINCT FROM v_my_agent_id THEN
    RAISE EXCEPTION 'Only the assigned agent or a trade administrator can link the opposite representation';
  END IF;

  IF v_primary.representation_group_id IS NULL
     OR v_primary.payload->>'opposite_side_dv_agent_id' IS DISTINCT FROM p_opposite_agent_id::text THEN
    RAISE EXCEPTION 'The primary submission does not authorize this opposite-side agent';
  END IF;

  IF v_primary.status NOT IN ('SUBMITTED', 'NEEDS_CHANGES')
     OR v_primary.transaction_id IS NULL THEN
    RAISE EXCEPTION 'Submit the primary representation before linking the opposite-side draft';
  END IF;

  IF p_representation_side NOT IN ('LANDLORD','TENANT','SELLER','BUYER')
     OR p_representation_side = v_primary.representation_side THEN
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
