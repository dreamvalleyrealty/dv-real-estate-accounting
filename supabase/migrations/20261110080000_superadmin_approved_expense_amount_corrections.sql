-- Add a dedicated permission and a controlled amount-correction workflow for approved expenses.
-- Corrections retain the original posting and payment history and post a balanced adjustment.

INSERT INTO public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
VALUES (
  'expenses.approved.edit',
  'Expenses & A/P',
  'Edit approved expense amount',
  'Correct the subtotal and HST on an approved, posted vendor invoice. Requires a reason and creates a balanced adjustment journal entry and audit history.',
  44
)
ON CONFLICT (code) DO UPDATE
SET module=EXCLUDED.module,
    label=EXCLUDED.label,
    description=EXCLUDED.description,
    sort_order=EXCLUDED.sort_order;

-- Super Admin has this capability by default. Other roles are denied until
-- a Super Admin grants an explicit role rule or user override.
INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope)
VALUES
  ('SUPERADMIN','expenses.approved.edit',true,'ALL'),
  ('ADMIN','expenses.approved.edit',false,'OWN'),
  ('MANAGER','expenses.approved.edit',false,'OWN'),
  ('STAFF','expenses.approved.edit',false,'OWN'),
  ('ACCOUNTANT','expenses.approved.edit',false,'OWN'),
  ('VIEWER','expenses.approved.edit',false,'OWN'),
  ('AGENT','expenses.approved.edit',false,'OWN')
ON CONFLICT (role,permission_code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.dv_accounting_correct_approved_expense_amount(
  p_expense_id uuid,
  p_amount numeric,
  p_hst_amount numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  e public.dv_accounting_expenses%rowtype;
  v_role text;
  v_allowed boolean := false;
  v_new_amount numeric(14,2);
  v_new_hst numeric(14,2);
  v_new_total numeric(14,2);
  v_old_total numeric(14,2);
  v_paid numeric(14,2) := 0;
  v_delta_amount numeric(14,2);
  v_delta_hst numeric(14,2);
  v_delta_total numeric(14,2);
  v_expense_gl uuid;
  v_hst_gl uuid;
  v_offset_gl uuid;
  v_adjustment_je uuid;
  v_new_payment_status text;
  v_before jsonb;
  v_after jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.dv_accounting_user_profiles
    WHERE user_id=auth.uid() AND coalesce(active,true)=true
  ) THEN
    RAISE EXCEPTION 'An active accounting user profile is required';
  END IF;

  v_role := public.dv_accounting_current_user_role();

  IF v_role IS DISTINCT FROM 'SUPERADMIN' THEN
    SELECT coalesce(u.allowed,r.allowed,false)
      INTO v_allowed
    FROM (SELECT 1) AS seed
    LEFT JOIN public.dv_accounting_role_permission_rules r
      ON r.role=v_role AND r.permission_code='expenses.approved.edit'
    LEFT JOIN public.dv_accounting_user_permission_overrides u
      ON u.user_id=auth.uid() AND u.permission_code='expenses.approved.edit';

    IF NOT coalesce(v_allowed,false) THEN
      RAISE EXCEPTION 'You do not have permission to edit approved expense amounts';
    END IF;
  END IF;

  IF nullif(trim(coalesce(p_reason,'')),'') IS NULL THEN
    RAISE EXCEPTION 'A correction reason is required';
  END IF;

  v_new_amount := round(coalesce(p_amount,0),2);
  v_new_hst := round(coalesce(p_hst_amount,0),2);
  v_new_total := round(v_new_amount+v_new_hst,2);

  IF v_new_amount < 0 OR v_new_hst < 0 OR v_new_total <= 0 THEN
    RAISE EXCEPTION 'The corrected subtotal and HST must be non-negative and the total must be greater than zero';
  END IF;

  SELECT * INTO e
  FROM public.dv_accounting_expenses
  WHERE id=p_expense_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Expense not found';
  END IF;
  IF e.approval_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'Only approved expenses can be corrected';
  END IF;
  IF e.posted_at IS NULL OR e.journal_entry_id IS NULL THEN
    RAISE EXCEPTION 'The expense must be posted before its amount can be corrected';
  END IF;
  IF e.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'A voided expense cannot be corrected';
  END IF;

  v_old_total := round(coalesce(e.amount,0)+coalesce(e.hst_amount,0),2);
  IF round(coalesce(e.amount,0),2)=v_new_amount
     AND round(coalesce(e.hst_amount,0),2)=v_new_hst THEN
    RAISE EXCEPTION 'No amount changes were entered';
  END IF;

  SELECT round(coalesce(sum(p.amount),0),2)
    INTO v_paid
  FROM public.dv_accounting_expense_payments p
  WHERE p.expense_id=e.id;

  -- Older invoices may have been marked paid before payment allocations were introduced.
  IF v_paid=0 AND e.payment_status='PAID' THEN
    v_paid := v_old_total;
  END IF;

  IF v_paid > v_new_total THEN
    RAISE EXCEPTION 'The corrected invoice total (%) is below the amount already paid (%). Record the vendor refund or credit separately before reducing the invoice total.',
      v_new_total, v_paid;
  END IF;

  SELECT jl.gl_account_id
    INTO v_expense_gl
  FROM public.dv_accounting_journal_lines jl
  JOIN public.dv_accounting_gl_accounts ga ON ga.id=jl.gl_account_id
  WHERE jl.journal_entry_id=e.journal_entry_id
    AND jl.debit>0
    AND upper(ga.account_type)='EXPENSE'
  ORDER BY jl.debit DESC
  LIMIT 1;

  SELECT jl.gl_account_id
    INTO v_offset_gl
  FROM public.dv_accounting_journal_lines jl
  WHERE jl.journal_entry_id=e.journal_entry_id
    AND jl.credit>0
  ORDER BY jl.credit DESC
  LIMIT 1;

  SELECT jl.gl_account_id
    INTO v_hst_gl
  FROM public.dv_accounting_journal_lines jl
  JOIN public.dv_accounting_gl_accounts ga ON ga.id=jl.gl_account_id
  WHERE jl.journal_entry_id=e.journal_entry_id
    AND jl.debit>0
    AND ga.code IN ('1300','1200')
  ORDER BY jl.debit DESC
  LIMIT 1;

  IF v_expense_gl IS NULL OR v_offset_gl IS NULL THEN
    RAISE EXCEPTION 'The original expense journal entry is incomplete. The amount cannot be corrected automatically; contact the accounting administrator';
  END IF;

  IF v_hst_gl IS NULL AND v_new_hst<>coalesce(e.hst_amount,0) THEN
    INSERT INTO public.dv_accounting_gl_accounts(company_id,code,name,account_type)
    VALUES(e.company_id,'1300','HST Input Tax Credits','ASSET')
    ON CONFLICT(company_id,code) DO NOTHING;

    SELECT id INTO v_hst_gl
    FROM public.dv_accounting_gl_accounts
    WHERE company_id=e.company_id AND code='1300';
  END IF;

  v_delta_amount := round(v_new_amount-coalesce(e.amount,0),2);
  v_delta_hst := round(v_new_hst-coalesce(e.hst_amount,0),2);
  v_delta_total := round(v_new_total-v_old_total,2);

  INSERT INTO public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
  VALUES(
    e.company_id,
    current_date,
    'EXPENSE_AMOUNT_ADJUSTMENT',
    e.id,
    'Approved expense amount correction: '||trim(p_reason)
  )
  RETURNING id INTO v_adjustment_je;

  IF v_delta_amount>0 THEN
    INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    VALUES(v_adjustment_je,v_expense_gl,v_delta_amount,0);
  ELSIF v_delta_amount<0 THEN
    INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    VALUES(v_adjustment_je,v_expense_gl,0,abs(v_delta_amount));
  END IF;

  IF v_delta_hst<>0 THEN
    IF v_hst_gl IS NULL THEN
      RAISE EXCEPTION 'The HST input tax credit account could not be found';
    END IF;
    IF v_delta_hst>0 THEN
      INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      VALUES(v_adjustment_je,v_hst_gl,v_delta_hst,0);
    ELSE
      INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
      VALUES(v_adjustment_je,v_hst_gl,0,abs(v_delta_hst));
    END IF;
  END IF;

  IF v_delta_total>0 THEN
    INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    VALUES(v_adjustment_je,v_offset_gl,0,v_delta_total);
  ELSIF v_delta_total<0 THEN
    INSERT INTO public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
    VALUES(v_adjustment_je,v_offset_gl,abs(v_delta_total),0);
  END IF;

  v_new_payment_status := CASE
    WHEN v_paid>=v_new_total THEN 'PAID'
    WHEN v_paid>0 THEN 'PARTIAL'
    ELSE 'UNPAID'
  END;

  v_before := jsonb_build_object(
    'amount',e.amount,
    'hst_amount',e.hst_amount,
    'total_amount',v_old_total,
    'payment_status',e.payment_status,
    'paid_amount',v_paid
  );
  v_after := jsonb_build_object(
    'amount',v_new_amount,
    'hst_amount',v_new_hst,
    'total_amount',v_new_total,
    'payment_status',v_new_payment_status,
    'paid_amount',v_paid,
    'adjustment_journal_entry_id',v_adjustment_je
  );

  UPDATE public.dv_accounting_expenses
  SET amount=v_new_amount,
      hst_amount=v_new_hst,
      payment_status=v_new_payment_status,
      paid_at=CASE WHEN v_new_payment_status='PAID' THEN coalesce(e.paid_at,now()) ELSE NULL END
  WHERE id=e.id;

  INSERT INTO public.dv_accounting_expense_audit(
    company_id,expense_id,action,reason,before_data,after_data,performed_by
  )
  VALUES(
    e.company_id,e.id,'EDIT_AMOUNT',trim(p_reason),v_before,v_after,auth.uid()
  );

  RETURN jsonb_build_object(
    'expense_id',e.id,
    'amount',v_new_amount,
    'hst_amount',v_new_hst,
    'total_amount',v_new_total,
    'payment_status',v_new_payment_status,
    'adjustment_journal_entry_id',v_adjustment_je
  );
END;
$$;

REVOKE ALL ON FUNCTION public.dv_accounting_correct_approved_expense_amount(uuid,numeric,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dv_accounting_correct_approved_expense_amount(uuid,numeric,numeric,text) TO authenticated;
