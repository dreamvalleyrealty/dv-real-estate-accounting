-- Recompile the transaction helper without relying on a stale composite-row
-- field reference. The listing id remains read from the submission payload.
DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_ensure_agent_trade_transaction(uuid)'::regprocedure)
    INTO v_definition;

  IF position('s.listing_id' in v_definition) > 0 THEN
    v_definition := replace(v_definition, 's.listing_id', 'null::uuid');
    EXECUTE v_definition;
  END IF;
END
$$;
