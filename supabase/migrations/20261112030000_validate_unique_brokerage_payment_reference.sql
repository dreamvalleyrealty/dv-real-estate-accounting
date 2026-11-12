-- Give a clear validation error when a brokerage batch reference has already been used.
-- The unique constraint remains the final concurrency safeguard.
DO $migration$
DECLARE
  v_definition text;
  v_anchor text := ' insert into public.dv_accounting_brokerage_payment_batches(id,company_id,source_bank_account_id,destination_bank_account_id,';
  v_guard text := $guard$
 if exists(
  select 1 from public.dv_accounting_brokerage_payment_batches b
  where b.company_id=v_company_id
    and upper(trim(b.payment_reference))=upper(trim(p_payment_reference))
 ) then
  raise exception 'Payment reference % has already been used for this company. Enter the new EFT or cheque reference from the bank.',trim(p_payment_reference);
 end if;

$guard$;
BEGIN
  SELECT pg_get_functiondef('public.dv_accounting_issue_brokerage_bulk_payment(uuid[],uuid,text,date)'::regprocedure)
    INTO v_definition;
  IF position(v_guard in v_definition)>0 THEN
    NULL;
  ELSIF position(v_anchor in v_definition)>0 THEN
    v_definition:=replace(v_definition,v_anchor,v_guard||v_anchor);
  ELSE
    RAISE EXCEPTION 'Could not locate brokerage batch insert point; migration stopped.';
  END IF;
  EXECUTE v_definition;
END
$migration$;
