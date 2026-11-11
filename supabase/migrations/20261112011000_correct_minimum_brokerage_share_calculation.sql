DO $migration$
DECLARE
  v_definition text;
  v_old text := 'agent_share:=GREATEST(
      ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2),
      GREATEST(ROUND(COALESCE(p_gross_commission,0)-500,2),0)
    );';
  v_new text := 'agent_share:=GREATEST(
      LEAST(
        ROUND(COALESCE(p_gross_commission,0)*split_pct/100,2),
        GREATEST(ROUND(COALESCE(p_gross_commission,0)-500,2),0)
      ),
      0
    );';
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_calculate_commission_fees(uuid,uuid,numeric,date)'::regprocedure)
    INTO v_definition;
  IF position(v_old in v_definition)>0 THEN
    EXECUTE replace(v_definition,v_old,v_new);
  ELSIF position(v_new in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate commission share calculation; migration stopped.';
  END IF;
END
$migration$;
