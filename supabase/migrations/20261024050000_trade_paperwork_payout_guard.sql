-- Keep billing transfer separate from trade-paperwork completion.
-- A trade may be transferred to Transactions, but commission cheques cannot be issued
-- while any attached document is awaiting review / declined or required paperwork is incomplete.

CREATE OR REPLACE FUNCTION public.dv_accounting_guard_commission_payout_for_trade_paperwork()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transaction_id uuid;
  v_company_id uuid;
  v_submission public.dv_accounting_agent_trade_submissions%rowtype;
  v_side text;
  v_required jsonb;
  v_side_rules jsonb;
  v_rules jsonb;
  v_counts jsonb;
  v_type text;
  v_needed integer;
  v_approved integer;
  v_missing text[] := ARRAY[]::text[];
  v_unreviewed integer := 0;
  v_rejected integer := 0;
BEGIN
  IF upper(coalesce(NEW.status, '')) <> 'ISSUED' THEN
    RETURN NEW;
  END IF;

  SELECT c.transaction_id INTO v_transaction_id
  FROM public.dv_accounting_commissions c
  WHERE c.id = NEW.commission_id;

  IF v_transaction_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT t.company_id INTO v_company_id
  FROM public.dv_accounting_transactions t
  WHERE t.id = v_transaction_id;

  SELECT s.* INTO v_submission
  FROM public.dv_accounting_agent_trade_submissions s
  WHERE s.transaction_id = v_transaction_id
  ORDER BY s.updated_at DESC NULLS LAST
  LIMIT 1;

  -- Legacy transactions not created from the Trade Submission workflow are unaffected.
  IF v_submission.id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_unreviewed
  FROM public.dv_accounting_agent_trade_documents d
  WHERE d.submission_id = v_submission.id
    AND upper(coalesce(d.match_status, 'PENDING')) NOT IN ('MATCH', 'APPROVED', 'NOT_APPLICABLE');

  SELECT count(*) INTO v_rejected
  FROM public.dv_accounting_agent_trade_documents d
  WHERE d.submission_id = v_submission.id
    AND upper(coalesce(d.match_status, 'PENDING')) IN ('MISMATCH', 'REJECTED', 'NOT_APPROVED', 'NOT APPROVED');

  IF v_unreviewed > 0 OR v_rejected > 0 THEN
    RAISE EXCEPTION 'Agent commission payout blocked: trade paperwork is incomplete. % document(s) need review and % document(s) are not approved. The agent must correct the paperwork and the Trade Admin Manager must approve it before payout.',
      v_unreviewed, v_rejected;
  END IF;

  SELECT value INTO v_required
  FROM public.dv_accounting_settings
  WHERE company_id = v_company_id AND key = 'TRADE_REQUIRED_DOCUMENT_TYPES'
  LIMIT 1;
  IF coalesce(jsonb_typeof(v_required), '') <> 'array' THEN
    v_required := '["APS","MLS","COMMISSION"]'::jsonb;
  END IF;

  SELECT value INTO v_counts
  FROM public.dv_accounting_settings
  WHERE company_id = v_company_id AND key = 'TRADE_REQUIRED_DOCUMENT_COUNTS'
  LIMIT 1;
  IF coalesce(jsonb_typeof(v_counts), '') <> 'object' THEN v_counts := '{}'::jsonb; END IF;

  v_side := upper(coalesce(v_submission.payload->>'side', 'BUYER'));
  SELECT value INTO v_side_rules
  FROM public.dv_accounting_settings
  WHERE company_id = v_company_id AND key = 'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE'
  LIMIT 1;

  v_rules := coalesce(
    v_side_rules->v_side,
    v_side_rules->(CASE WHEN v_side IN ('SELLER','LANDLORD','LISTING') THEN 'LISTING' ELSE v_side END),
    '{}'::jsonb
  );
  IF jsonb_typeof(v_rules->'required') = 'array' THEN
    v_required := v_rules->'required';
  ELSIF jsonb_typeof(v_rules->'types') = 'array' THEN
    v_required := v_rules->'types';
  END IF;
  IF jsonb_typeof(v_rules->'counts') = 'object' THEN
    v_counts := v_rules->'counts';
  END IF;

  FOR v_type IN SELECT jsonb_array_elements_text(v_required)
  LOOP
    v_needed := greatest(coalesce(nullif(v_counts->>v_type, '')::integer, 1), 1);
    SELECT count(*) INTO v_approved
    FROM public.dv_accounting_agent_trade_documents d
    WHERE d.submission_id = v_submission.id
      AND upper(coalesce(d.document_type, 'OTHER')) = upper(v_type)
      AND upper(coalesce(d.match_status, 'PENDING')) IN ('MATCH', 'APPROVED');

    IF v_approved < v_needed THEN
      v_missing := array_append(v_missing, v_type || ' (' || v_approved::text || '/' || v_needed::text || ' approved)');
    END IF;
  END LOOP;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'Agent commission payout blocked: required trade paperwork is incomplete: %. Correct or upload the missing documents and obtain admin approval before issuing the commission cheque.',
      array_to_string(v_missing, ', ');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dv_accounting_guard_trade_paperwork_before_commission_cheque
  ON public.dv_accounting_commission_cheques;

CREATE TRIGGER dv_accounting_guard_trade_paperwork_before_commission_cheque
BEFORE INSERT OR UPDATE OF status ON public.dv_accounting_commission_cheques
FOR EACH ROW
EXECUTE FUNCTION public.dv_accounting_guard_commission_payout_for_trade_paperwork();

REVOKE ALL ON FUNCTION public.dv_accounting_guard_commission_payout_for_trade_paperwork() FROM PUBLIC, anon, authenticated;
