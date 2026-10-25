-- Avoid recursive submission/transaction date synchronization when the draft-sync trigger
-- updates transaction rows and the existing date-sync trigger writes dates back to the submission.

CREATE OR REPLACE FUNCTION public.dv_accounting_sync_submission_to_draft_transaction()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

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
