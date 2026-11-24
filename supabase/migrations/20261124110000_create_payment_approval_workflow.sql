-- Stage 1: payment approval workflow records and permission catalog.
-- This migration is committed to the feature branch only. It is not applied to production.
-- Payment records are append-only through controlled RPCs added in a later stage.

CREATE TABLE IF NOT EXISTS public.dv_accounting_payment_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.dv_accounting_companies(id) ON DELETE RESTRICT,
  payment_type text NOT NULL
    CHECK (payment_type IN ('AGENT_COMMISSION','COOPERATING_BROKERAGE','BROKERAGE_TRANSFER')),
  status text NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','PENDING_APPROVAL','RETURNED','APPROVED','REJECTED','ISSUED','CANCELLED')),
  prepared_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  prepared_at timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz,
  reviewed_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  reviewed_at timestamptz,
  review_note text,
  issued_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  issued_at timestamptz,
  payment_method text CHECK (payment_method IS NULL OR payment_method IN ('CHEQUE','EFT','INTERNAL_TRANSFER')),
  payment_reference text,
  payment_date date,
  total_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  currency text NOT NULL DEFAULT 'CAD' CHECK (currency = 'CAD'),
  calculation_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(calculation_snapshot) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dv_payment_approval_review_separation
    CHECK (reviewed_by IS NULL OR reviewed_by <> prepared_by),
  CONSTRAINT dv_payment_approval_issue_separation
    CHECK (issued_by IS NULL OR issued_by <> prepared_by),
  CONSTRAINT dv_payment_approval_review_metadata
    CHECK (
      (reviewed_by IS NULL AND reviewed_at IS NULL)
      OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    ),
  CONSTRAINT dv_payment_approval_issue_metadata
    CHECK (
      (issued_by IS NULL AND issued_at IS NULL)
      OR (issued_by IS NOT NULL AND issued_at IS NOT NULL)
    ),
  CONSTRAINT dv_payment_approval_issued_reference
    CHECK (
      status <> 'ISSUED'
      OR (
        issued_by IS NOT NULL
        AND issued_at IS NOT NULL
        AND payment_date IS NOT NULL
        AND nullif(btrim(payment_reference), '') IS NOT NULL
        AND payment_method IS NOT NULL
      )
    ),
  CONSTRAINT dv_payment_approval_submission_metadata
    CHECK (
      status NOT IN ('PENDING_APPROVAL','RETURNED','APPROVED','REJECTED','ISSUED')
      OR submitted_at IS NOT NULL
    ),
  CONSTRAINT dv_payment_approval_reviewed_status_metadata
    CHECK (
      status NOT IN ('RETURNED','APPROVED','REJECTED','ISSUED')
      OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    )
);

CREATE TABLE IF NOT EXISTS public.dv_accounting_payment_approval_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id uuid NOT NULL
    REFERENCES public.dv_accounting_payment_approvals(id) ON DELETE RESTRICT,
  transaction_id uuid NOT NULL
    REFERENCES public.dv_accounting_transactions(id) ON DELETE RESTRICT,
  source_agent_commission_id uuid
    REFERENCES public.dv_accounting_commissions(id) ON DELETE RESTRICT,
  source_transaction_commission_id uuid
    REFERENCES public.dv_accounting_transaction_commissions(id) ON DELETE RESTRICT,
  source_brokerage_commission_id uuid
    REFERENCES public.dv_accounting_commissions(id) ON DELETE RESTRICT,
  payee_name text NOT NULL CHECK (length(btrim(payee_name)) > 0),
  base_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (base_amount >= 0),
  hst_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (hst_amount >= 0),
  total_amount numeric(14,2) NOT NULL CHECK (total_amount > 0),
  calculation_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(calculation_snapshot) = 'object'),
  commission_cheque_id uuid
    REFERENCES public.dv_accounting_commission_cheques(id) ON DELETE RESTRICT,
  brokerage_payment_item_id uuid
    REFERENCES public.dv_accounting_brokerage_payment_items(id) ON DELETE RESTRICT,
  trust_transaction_id uuid
    REFERENCES public.dv_accounting_trust_transactions(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dv_payment_approval_item_one_source
    CHECK (num_nonnulls(
      source_agent_commission_id,
      source_transaction_commission_id,
      source_brokerage_commission_id
    ) = 1),
  CONSTRAINT dv_payment_approval_item_amounts
    CHECK (round(base_amount + hst_amount, 2) = total_amount)
);

CREATE INDEX IF NOT EXISTS idx_dv_payment_approvals_status_created
  ON public.dv_accounting_payment_approvals(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dv_payment_approvals_company_type
  ON public.dv_accounting_payment_approvals(company_id, payment_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dv_payment_approvals_prepared_by
  ON public.dv_accounting_payment_approvals(prepared_by, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dv_payment_approval_items_approval
  ON public.dv_accounting_payment_approval_items(approval_id);
CREATE INDEX IF NOT EXISTS idx_dv_payment_approval_items_transaction
  ON public.dv_accounting_payment_approval_items(transaction_id);
CREATE INDEX IF NOT EXISTS idx_dv_payment_approval_items_agent_commission
  ON public.dv_accounting_payment_approval_items(source_agent_commission_id)
  WHERE source_agent_commission_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dv_payment_approval_items_coop_commission
  ON public.dv_accounting_payment_approval_items(source_transaction_commission_id)
  WHERE source_transaction_commission_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dv_payment_approval_items_brokerage_commission
  ON public.dv_accounting_payment_approval_items(source_brokerage_commission_id)
  WHERE source_brokerage_commission_id IS NOT NULL;

ALTER TABLE public.dv_accounting_payment_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dv_accounting_payment_approval_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dv_payment_approvals_read_permission
  ON public.dv_accounting_payment_approvals;
CREATE POLICY dv_payment_approvals_read_permission
  ON public.dv_accounting_payment_approvals
  FOR SELECT TO authenticated
  USING (
    public.dv_accounting_has_permission_all_scope('payments.view')
    OR public.dv_accounting_has_permission_all_scope('payments.prepare')
    OR public.dv_accounting_has_permission_all_scope('payments.approve')
    OR public.dv_accounting_has_permission_all_scope('payments.issue')
  );

DROP POLICY IF EXISTS dv_payment_approval_items_read_permission
  ON public.dv_accounting_payment_approval_items;
CREATE POLICY dv_payment_approval_items_read_permission
  ON public.dv_accounting_payment_approval_items
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.dv_accounting_payment_approvals a
      WHERE a.id = approval_id
    )
  );

-- The browser can read rows allowed by RLS. All writes will be performed by
-- authenticated, permission-checked RPCs; direct table mutation is prohibited.
REVOKE ALL ON TABLE public.dv_accounting_payment_approvals
  FROM anon, authenticated;
REVOKE ALL ON TABLE public.dv_accounting_payment_approval_items
  FROM anon, authenticated;
GRANT SELECT ON TABLE public.dv_accounting_payment_approvals
  TO authenticated;
GRANT SELECT ON TABLE public.dv_accounting_payment_approval_items
  TO authenticated;

INSERT INTO public.dv_accounting_permission_catalog
  (code, module, label, description, sort_order)
VALUES
  ('payments.view', 'Payments Centre', 'View Payments Centre', 'View payment requests, approvals and payment history.', 73),
  ('payments.prepare', 'Payments Centre', 'Prepare payment requests', 'Prepare and submit agent, co-operating brokerage and brokerage transfer payments for review.', 74),
  ('payments.approve', 'Payments Centre', 'Approve payment requests', 'Approve or return payment requests prepared by another user.', 75),
  ('payments.issue', 'Payments Centre', 'Issue approved payments', 'Issue approved payments and post their accounting entries.', 76)
ON CONFLICT (code) DO UPDATE
SET module = EXCLUDED.module,
    label = EXCLUDED.label,
    description = EXCLUDED.description,
    sort_order = EXCLUDED.sort_order;

-- Seed defaults only for the new permission codes. Existing role overrides and
-- all existing commission/banking permissions remain unchanged.
INSERT INTO public.dv_accounting_role_permission_rules
  (role, permission_code, allowed, access_scope, updated_at)
VALUES
  ('SUPERADMIN','payments.view',true,'ALL',now()),
  ('SUPERADMIN','payments.prepare',true,'ALL',now()),
  ('SUPERADMIN','payments.approve',true,'ALL',now()),
  ('SUPERADMIN','payments.issue',true,'ALL',now()),
  ('ADMIN','payments.view',true,'ALL',now()),
  ('ADMIN','payments.prepare',false,'ALL',now()),
  ('ADMIN','payments.approve',true,'ALL',now()),
  ('ADMIN','payments.issue',true,'ALL',now()),
  ('MANAGER','payments.view',true,'ALL',now()),
  ('MANAGER','payments.prepare',true,'ALL',now()),
  ('MANAGER','payments.approve',false,'ALL',now()),
  ('MANAGER','payments.issue',false,'ALL',now()),
  ('ACCOUNTANT','payments.view',true,'ALL',now()),
  ('ACCOUNTANT','payments.prepare',false,'ALL',now()),
  ('ACCOUNTANT','payments.approve',false,'ALL',now()),
  ('ACCOUNTANT','payments.issue',false,'ALL',now()),
  ('STAFF','payments.view',false,'OWN',now()),
  ('STAFF','payments.prepare',false,'OWN',now()),
  ('STAFF','payments.approve',false,'OWN',now()),
  ('STAFF','payments.issue',false,'OWN',now()),
  ('VIEWER','payments.view',false,'ALL',now()),
  ('VIEWER','payments.prepare',false,'ALL',now()),
  ('VIEWER','payments.approve',false,'ALL',now()),
  ('VIEWER','payments.issue',false,'ALL',now()),
  ('AGENT','payments.view',false,'OWN',now()),
  ('AGENT','payments.prepare',false,'OWN',now()),
  ('AGENT','payments.approve',false,'OWN',now()),
  ('AGENT','payments.issue',false,'OWN',now())
ON CONFLICT (role, permission_code) DO NOTHING;


-- Validate each source link against its payment type and the parent trade/company.
CREATE OR REPLACE FUNCTION public.dv_accounting_validate_payment_approval_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_payment_type text;
  v_source_transaction_id uuid;
  v_transaction_company_id uuid;
  v_approval_company_id uuid;
BEGIN
  SELECT a.payment_type, a.company_id
    INTO v_payment_type, v_approval_company_id
  FROM public.dv_accounting_payment_approvals a
  WHERE a.id = NEW.approval_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment approval request was not found';
  END IF;

  IF v_payment_type = 'AGENT_COMMISSION' THEN
    IF NEW.source_agent_commission_id IS NULL
       OR NEW.source_transaction_commission_id IS NOT NULL
       OR NEW.source_brokerage_commission_id IS NOT NULL THEN
      RAISE EXCEPTION 'Agent commission payment item has an invalid source link';
    END IF;
    SELECT c.transaction_id INTO v_source_transaction_id
    FROM public.dv_accounting_commissions c
    WHERE c.id = NEW.source_agent_commission_id;
  ELSIF v_payment_type = 'COOPERATING_BROKERAGE' THEN
    IF NEW.source_transaction_commission_id IS NULL
       OR NEW.source_agent_commission_id IS NOT NULL
       OR NEW.source_brokerage_commission_id IS NOT NULL THEN
      RAISE EXCEPTION 'Co-operating brokerage payment item has an invalid source link';
    END IF;
    SELECT tc.transaction_id INTO v_source_transaction_id
    FROM public.dv_accounting_transaction_commissions tc
    WHERE tc.id = NEW.source_transaction_commission_id
      AND tc.settlement_direction = 'PAYABLE';
  ELSIF v_payment_type = 'BROKERAGE_TRANSFER' THEN
    IF NEW.source_brokerage_commission_id IS NULL
       OR NEW.source_agent_commission_id IS NOT NULL
       OR NEW.source_transaction_commission_id IS NOT NULL THEN
      RAISE EXCEPTION 'Brokerage transfer payment item has an invalid source link';
    END IF;
    SELECT c.transaction_id INTO v_source_transaction_id
    FROM public.dv_accounting_commissions c
    WHERE c.id = NEW.source_brokerage_commission_id;
  ELSE
    RAISE EXCEPTION 'Unsupported payment type';
  END IF;

  IF v_source_transaction_id IS NULL OR v_source_transaction_id <> NEW.transaction_id THEN
    RAISE EXCEPTION 'Payment item source does not match the selected transaction';
  END IF;

  SELECT t.company_id INTO v_transaction_company_id
  FROM public.dv_accounting_transactions t
  WHERE t.id = NEW.transaction_id;

  IF v_transaction_company_id IS NULL OR v_transaction_company_id <> v_approval_company_id THEN
    RAISE EXCEPTION 'Payment approval company does not match the transaction company';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.dv_accounting_validate_payment_approval_item()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS dv_accounting_validate_payment_approval_item
  ON public.dv_accounting_payment_approval_items;
CREATE TRIGGER dv_accounting_validate_payment_approval_item
  BEFORE INSERT OR UPDATE ON public.dv_accounting_payment_approval_items
  FOR EACH ROW
  EXECUTE FUNCTION public.dv_accounting_validate_payment_approval_item();

-- Add the same audit capture used by existing commission and cheque records.
DROP TRIGGER IF EXISTS dv_accounting_audit_trigger
  ON public.dv_accounting_payment_approvals;
CREATE TRIGGER dv_accounting_audit_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.dv_accounting_payment_approvals
  FOR EACH ROW
  EXECUTE FUNCTION public.dv_accounting_capture_audit_log();

DROP TRIGGER IF EXISTS dv_accounting_audit_trigger
  ON public.dv_accounting_payment_approval_items;
CREATE TRIGGER dv_accounting_audit_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.dv_accounting_payment_approval_items
  FOR EACH ROW
  EXECUTE FUNCTION public.dv_accounting_capture_audit_log();

COMMENT ON TABLE public.dv_accounting_payment_approvals IS
  'Approval workflow header for payment preparation, independent review and issuance.';
COMMENT ON TABLE public.dv_accounting_payment_approval_items IS
  'Immutable calculation snapshots and source/result links for individual payment items.';
