-- Automatically create and synchronize a draft accounting transaction as soon as a trade is submitted.
-- Document approval remains a separate admin workflow; this does not approve paperwork or release commissions.

DO $migration$
DECLARE
  v_definition text;
  v_old text := E'  if not public.dv_accounting_is_trade_admin() then\n    raise exception ''Only a trade administrator can create or update the linked transaction'';\n  end if;';
  v_new text := E'  if not public.dv_accounting_is_trade_admin() and not exists (\n    select 1\n    from public.dv_accounting_agent_trade_submissions own_submission\n    where own_submission.id = p_submission_id\n      and own_submission.agent_id = public.dv_accounting_my_agent_id()\n      and own_submission.status in (''SUBMITTED'', ''NEEDS_CHANGES'')\n  ) then\n    raise exception ''Only an administrator or the assigned agent for an active submitted trade can synchronize the linked transaction'';\n  end if;';
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_ensure_agent_trade_transaction(uuid)'::regprocedure)
    INTO v_definition;

  IF position(v_old in v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not locate the expected authorization guard in dv_accounting_ensure_agent_trade_transaction; aborting migration.';
  END IF;

  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END
$migration$;

CREATE OR REPLACE FUNCTION public.dv_accounting_sync_submission_to_draft_transaction()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status IN ('SUBMITTED', 'NEEDS_CHANGES') THEN
      PERFORM public.dv_accounting_ensure_agent_trade_transaction(NEW.id);
    END IF;
  ELSIF NEW.status IN ('SUBMITTED', 'NEEDS_CHANGES')
      AND (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.status IS DISTINCT FROM OLD.status) THEN
    PERFORM public.dv_accounting_ensure_agent_trade_transaction(NEW.id);
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_auto_create_trade_submission_transaction ON public.dv_accounting_agent_trade_submissions;
CREATE TRIGGER trg_auto_create_trade_submission_transaction
AFTER INSERT ON public.dv_accounting_agent_trade_submissions
FOR EACH ROW
EXECUTE FUNCTION public.dv_accounting_sync_submission_to_draft_transaction();

DROP TRIGGER IF EXISTS trg_sync_trade_submission_draft_transaction ON public.dv_accounting_agent_trade_submissions;
CREATE TRIGGER trg_sync_trade_submission_draft_transaction
AFTER UPDATE OF payload, status ON public.dv_accounting_agent_trade_submissions
FOR EACH ROW
WHEN (NEW.status IN ('SUBMITTED', 'NEEDS_CHANGES'))
EXECUTE FUNCTION public.dv_accounting_sync_submission_to_draft_transaction();

COMMENT ON FUNCTION public.dv_accounting_sync_submission_to_draft_transaction()
IS 'Creates and synchronizes the linked DRAFT accounting transaction for submitted trade payloads without approving any trade documents.';
