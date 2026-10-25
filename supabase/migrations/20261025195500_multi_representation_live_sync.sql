-- Allow an assigned agent to keep an already-linked opposite-side draft in sync.
-- Keep the transaction's gross commission sourced from the seller/landlord-side
-- representation, where both side commission fields are available.
DO $migration$
DECLARE
  v_definition text;
  v_old_guard text := $oldguard$  if not public.dv_accounting_is_trade_admin() and not exists (
    select 1
    from public.dv_accounting_agent_trade_submissions own_submission
    where own_submission.id = p_submission_id
      and own_submission.agent_id = public.dv_accounting_my_agent_id()
      and own_submission.status in ('SUBMITTED', 'NEEDS_CHANGES')
  ) then
    raise exception 'Only an administrator or the assigned agent for an active submitted trade can synchronize the linked transaction';
  end if;$oldguard$;
  v_new_guard text := $newguard$  if not public.dv_accounting_is_trade_admin() and not exists (
    select 1
    from public.dv_accounting_agent_trade_submissions own_submission
    where own_submission.id = p_submission_id
      and own_submission.agent_id = public.dv_accounting_my_agent_id()
      and (
        own_submission.status in ('SUBMITTED', 'NEEDS_CHANGES')
        or (own_submission.status = 'DRAFT'
            and own_submission.representation_group_id is not null
            and own_submission.transaction_id is not null)
      )
  ) then
    raise exception 'Only the assigned agent for an active submission or a linked representation draft can synchronize the transaction';
  end if;$newguard$;
  v_old_side text := $oldside$  IF s.representation_group_id IS NOT NULL THEN
    p := jsonb_set(p, '{side}', to_jsonb(coalesce((
      SELECT nullif(trim(primary_side.payload->>'side'), '')
      FROM public.dv_accounting_agent_trade_submissions primary_side
      WHERE primary_side.representation_group_id = s.representation_group_id
        AND primary_side.id <> s.id
        AND nullif(trim(coalesce(primary_side.payload->>'opposite_side_dv_agent_id','')), '') IS NOT NULL
      ORDER BY primary_side.created_at
      LIMIT 1
    ), p->>'side')), true);
  END IF;$oldside$;
  v_new_side text := $newside$  IF s.representation_group_id IS NOT NULL THEN
    p := jsonb_set(p, '{side}', to_jsonb(coalesce((
      SELECT nullif(trim(primary_side.payload->>'side'), '')
      FROM public.dv_accounting_agent_trade_submissions primary_side
      WHERE primary_side.representation_group_id = s.representation_group_id
        AND primary_side.id <> s.id
        AND nullif(trim(coalesce(primary_side.payload->>'opposite_side_dv_agent_id','')), '') IS NOT NULL
      ORDER BY primary_side.created_at
      LIMIT 1
    ), p->>'side')), true);

    p := jsonb_set(p, '{gross_commission}', to_jsonb(coalesce((
      SELECT nullif(trim(commission_side.payload->>'gross_commission'), '')::numeric
      FROM public.dv_accounting_agent_trade_submissions commission_side
      WHERE commission_side.representation_group_id = s.representation_group_id
        AND commission_side.representation_side IN ('SELLER', 'LANDLORD')
      ORDER BY commission_side.created_at
      LIMIT 1
    ), nullif(trim(p->>'gross_commission'), '')::numeric, 0)), true);
  END IF;$newside$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_ensure_agent_trade_transaction(uuid)'::regprocedure)
    INTO v_definition;

  IF position(v_old_guard in v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not find expected authorization guard in dv_accounting_ensure_agent_trade_transaction';
  END IF;
  IF position(v_old_side in v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not find expected representation-side sync block in dv_accounting_ensure_agent_trade_transaction';
  END IF;

  v_definition := replace(v_definition, v_old_guard, v_new_guard);
  v_definition := replace(v_definition, v_old_side, v_new_side);
  EXECUTE v_definition;
END
$migration$;
