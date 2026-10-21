-- Keep the submission trade_number column and payload.transaction_number synchronized.
-- Explicit admin edits win; transaction-number sync updates must not be overwritten
-- by a stale trade_number value from the previous submission row.
CREATE OR REPLACE FUNCTION public.dv_preserve_agent_trade_submission_payload()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_trade_number text;
  v_new_trade_number text;
  v_old_trade_number text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_new_trade_number := nullif(btrim(NEW.trade_number), '');
    v_old_trade_number := nullif(btrim(OLD.trade_number), '');

    IF v_new_trade_number IS NOT NULL AND v_new_trade_number IS DISTINCT FROM v_old_trade_number THEN
      v_trade_number := v_new_trade_number;
    ELSIF nullif(btrim(NEW.payload->>'transaction_number'), '') IS NOT NULL
      AND nullif(btrim(NEW.payload->>'transaction_number'), '') IS DISTINCT FROM nullif(btrim(OLD.payload->>'transaction_number'), '') THEN
      v_trade_number := nullif(btrim(NEW.payload->>'transaction_number'), '');
    ELSE
      v_trade_number := coalesce(
        v_old_trade_number,
        v_new_trade_number,
        nullif(btrim(OLD.payload->>'transaction_number'), ''),
        nullif(btrim(NEW.payload->>'transaction_number'), '')
      );
    END IF;

    NEW.trade_number := v_trade_number;
    NEW.payload := coalesce(OLD.payload, '{}'::jsonb) || coalesce(NEW.payload, '{}'::jsonb);
    IF v_trade_number IS NOT NULL THEN
      NEW.payload := jsonb_set(NEW.payload, '{transaction_number}', to_jsonb(v_trade_number), true);
    ELSE
      NEW.payload := NEW.payload - 'transaction_number';
    END IF;
  ELSE
    NEW.payload := coalesce(NEW.payload, '{}'::jsonb);
    v_trade_number := coalesce(
      nullif(btrim(NEW.trade_number), ''),
      nullif(btrim(NEW.payload->>'transaction_number'), '')
    );
    IF v_trade_number IS NOT NULL THEN
      NEW.trade_number := v_trade_number;
      NEW.payload := jsonb_set(NEW.payload, '{transaction_number}', to_jsonb(v_trade_number), true);
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
