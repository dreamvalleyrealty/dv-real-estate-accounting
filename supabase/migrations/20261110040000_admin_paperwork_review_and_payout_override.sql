-- Audited, one-time administrator authorization to issue commission despite incomplete trade paperwork.
CREATE TABLE IF NOT EXISTS public.dv_accounting_paperwork_payout_authorizations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 commission_id uuid NOT NULL REFERENCES public.dv_accounting_commissions(id) ON DELETE CASCADE,
 transaction_id uuid NOT NULL REFERENCES public.dv_accounting_transactions(id) ON DELETE CASCADE,
 reason text NOT NULL CHECK (length(trim(reason)) >= 10),
 authorized_by uuid NOT NULL REFERENCES auth.users(id),
 authorized_at timestamptz NOT NULL DEFAULT now(),
 consumed_by_cheque_id uuid REFERENCES public.dv_accounting_commission_cheques(id),
 consumed_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_paperwork_payout_authorizations_commission
 ON public.dv_accounting_paperwork_payout_authorizations(commission_id,authorized_at DESC);
ALTER TABLE public.dv_accounting_paperwork_payout_authorizations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dv_accounting_paperwork_payout_authorizations FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_authorize_paperwork_payout(p_commission_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_transaction_id uuid; v_id uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.dv_accounting_has_permission_all_scope('commission.issue'::text) THEN
   RAISE EXCEPTION 'You do not have permission to authorize a paperwork exception.';
 END IF;
 IF length(trim(coalesce(p_reason,''))) < 10 THEN
   RAISE EXCEPTION 'Enter an authorization reason of at least 10 characters.';
 END IF;
 SELECT transaction_id INTO v_transaction_id FROM public.dv_accounting_commissions WHERE id=p_commission_id;
 IF v_transaction_id IS NULL THEN RAISE EXCEPTION 'Commission record not found.'; END IF;
 INSERT INTO public.dv_accounting_paperwork_payout_authorizations
   (commission_id,transaction_id,reason,authorized_by)
 VALUES (p_commission_id,v_transaction_id,trim(p_reason),auth.uid())
 RETURNING id INTO v_id;
 RETURN jsonb_build_object('authorization_id',v_id,'transaction_id',v_transaction_id,'authorized_at',now());
END $$;
REVOKE ALL ON FUNCTION public.dv_accounting_authorize_paperwork_payout(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_authorize_paperwork_payout(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.dv_accounting_guard_commission_payout_for_trade_paperwork()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_transaction_id uuid;
 v_company_id uuid;
 v_submission public.dv_accounting_agent_trade_submissions%rowtype;
 v_side text; v_required jsonb; v_side_rules jsonb; v_rules jsonb; v_counts jsonb;
 v_type text; v_needed integer; v_approved integer;
 v_missing text[]:=ARRAY[]::text[];
 v_unreviewed integer:=0; v_rejected integer:=0;
 v_authorization_id uuid;
BEGIN
 IF upper(coalesce(NEW.status,''))<>'ISSUED' THEN RETURN NEW; END IF;
 SELECT c.transaction_id INTO v_transaction_id FROM public.dv_accounting_commissions c WHERE c.id=NEW.commission_id;
 IF v_transaction_id IS NULL THEN RETURN NEW; END IF;
 SELECT t.company_id INTO v_company_id FROM public.dv_accounting_transactions t WHERE t.id=v_transaction_id;
 SELECT s.* INTO v_submission FROM public.dv_accounting_agent_trade_submissions s
 WHERE s.transaction_id=v_transaction_id ORDER BY s.updated_at DESC NULLS LAST LIMIT 1;
 IF v_submission.id IS NULL THEN RETURN NEW; END IF;

 -- A separately authorized, reasoned exception is consumed once and recorded against this cheque.
 SELECT id INTO v_authorization_id
 FROM public.dv_accounting_paperwork_payout_authorizations
 WHERE commission_id=NEW.commission_id AND transaction_id=v_transaction_id
   AND consumed_at IS NULL
 ORDER BY authorized_at DESC LIMIT 1 FOR UPDATE;
 IF v_authorization_id IS NOT NULL THEN
   UPDATE public.dv_accounting_paperwork_payout_authorizations
   SET consumed_by_cheque_id=NULL,consumed_at=now()
   WHERE id=v_authorization_id;
   RETURN NEW;
 END IF;

 SELECT count(*) INTO v_unreviewed FROM public.dv_accounting_agent_trade_documents d
 WHERE d.submission_id=v_submission.id
 AND upper(coalesce(d.match_status,'PENDING')) NOT IN ('MATCH','APPROVED','NOT_APPLICABLE');
 SELECT count(*) INTO v_rejected FROM public.dv_accounting_agent_trade_documents d
 WHERE d.submission_id=v_submission.id
 AND upper(coalesce(d.match_status,'PENDING')) IN ('MISMATCH','REJECTED','NOT_APPROVED','NOT APPROVED');
 IF v_unreviewed>0 OR v_rejected>0 THEN
   RAISE EXCEPTION 'Agent commission payout blocked: trade paperwork is incomplete. % document(s) need review and % document(s) are not approved. Review the paperwork or record an authorized exception.',v_unreviewed,v_rejected;
 END IF;
 SELECT value INTO v_required FROM public.dv_accounting_settings WHERE company_id=v_company_id AND key='TRADE_REQUIRED_DOCUMENT_TYPES' LIMIT 1;
 IF coalesce(jsonb_typeof(v_required),'')<>'array' THEN v_required:='["APS","MLS","COMMISSION"]'::jsonb; END IF;
 SELECT value INTO v_counts FROM public.dv_accounting_settings WHERE company_id=v_company_id AND key='TRADE_REQUIRED_DOCUMENT_COUNTS' LIMIT 1;
 IF coalesce(jsonb_typeof(v_counts),'')<>'object' THEN v_counts:='{}'::jsonb; END IF;
 v_side:=upper(coalesce(v_submission.payload->>'side','BUYER'));
 SELECT value INTO v_side_rules FROM public.dv_accounting_settings WHERE company_id=v_company_id AND key='TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE' LIMIT 1;
 v_rules:=coalesce(v_side_rules->v_side,v_side_rules->(CASE WHEN v_side IN ('SELLER','LANDLORD','LISTING') THEN 'LISTING' ELSE v_side END),'{}'::jsonb);
 IF jsonb_typeof(v_rules->'required')='array' THEN v_required:=v_rules->'required';
 ELSIF jsonb_typeof(v_rules->'types')='array' THEN v_required:=v_rules->'types'; END IF;
 IF jsonb_typeof(v_rules->'counts')='object' THEN v_counts:=v_rules->'counts'; END IF;
 FOR v_type IN SELECT jsonb_array_elements_text(v_required) LOOP
   v_needed:=greatest(coalesce(nullif(v_counts->>v_type,'')::integer,1),1);
   SELECT count(*) INTO v_approved FROM public.dv_accounting_agent_trade_documents d
   WHERE d.submission_id=v_submission.id AND upper(coalesce(d.document_type,'OTHER'))=upper(v_type)
     AND upper(coalesce(d.match_status,'PENDING')) IN ('MATCH','APPROVED');
   IF v_approved<v_needed THEN v_missing:=array_append(v_missing,v_type||' ('||v_approved::text||'/'||v_needed::text||' approved)'); END IF;
 END LOOP;
 IF coalesce(array_length(v_missing,1),0)>0 THEN
   RAISE EXCEPTION 'Agent commission payout blocked: required trade paperwork is incomplete: %. Review or authorize an exception before issuing payment.',array_to_string(v_missing,', ');
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.dv_accounting_guard_commission_payout_for_trade_paperwork() FROM PUBLIC,anon,authenticated;


-- Link the authorization to the cheque only after the cheque row exists.
CREATE OR REPLACE FUNCTION public.dv_accounting_link_paperwork_authorization_to_cheque()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
BEGIN
  UPDATE public.dv_accounting_paperwork_payout_authorizations a
  SET consumed_by_cheque_id=NEW.id
  WHERE a.id=(
    SELECT id
    FROM public.dv_accounting_paperwork_payout_authorizations
    WHERE commission_id=NEW.commission_id
      AND transaction_id=(SELECT transaction_id FROM public.dv_accounting_commissions WHERE id=NEW.commission_id)
      AND consumed_at IS NOT NULL
      AND consumed_by_cheque_id IS NULL
    ORDER BY consumed_at DESC,authorized_at DESC
    LIMIT 1
    FOR UPDATE
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS dv_accounting_link_paperwork_authorization_after_cheque
 ON public.dv_accounting_commission_cheques;
CREATE TRIGGER dv_accounting_link_paperwork_authorization_after_cheque
AFTER INSERT ON public.dv_accounting_commission_cheques
FOR EACH ROW
WHEN (upper(coalesce(NEW.status,''))='ISSUED')
EXECUTE FUNCTION public.dv_accounting_link_paperwork_authorization_to_cheque();
REVOKE ALL ON FUNCTION public.dv_accounting_link_paperwork_authorization_to_cheque() FROM PUBLIC,anon,authenticated;
