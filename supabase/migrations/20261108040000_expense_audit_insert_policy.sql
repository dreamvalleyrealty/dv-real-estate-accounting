-- Allow users who can edit all expenses to write the corresponding audit history.
-- Keep audit inserts aligned with the expense-edit permission used by the expense table.
DROP POLICY IF EXISTS "Authorized expense editors can insert expense audit"
  ON public.dv_accounting_expense_audit;

CREATE POLICY "Authorized expense editors can insert expense audit"
  ON public.dv_accounting_expense_audit
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.dv_accounting_has_permission_all_scope('expenses.edit')
  );
