
CREATE OR REPLACE FUNCTION public.dv_accounting_has_permission(p_permission_code text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.dv_accounting_current_user_role()='SUPERADMIN'
    OR coalesce((public.dv_accounting_get_my_permissions()->p_permission_code->>'allowed')::boolean,false)
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_has_permission_all_scope(p_permission_code text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.dv_accounting_current_user_role()='SUPERADMIN'
    OR (
      coalesce((public.dv_accounting_get_my_permissions()->p_permission_code->>'allowed')::boolean,false)
      AND coalesce(public.dv_accounting_get_my_permissions()->p_permission_code->>'scope','OWN')='ALL'
    )
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_has_any_permission_all_scope(p_permission_codes text[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.dv_accounting_current_user_role()='SUPERADMIN'
    OR EXISTS (
      SELECT 1 FROM unnest(coalesce(p_permission_codes,ARRAY[]::text[])) AS c(code)
      WHERE public.dv_accounting_has_permission_all_scope(c.code)
    )
$function$;

INSERT INTO public.dv_accounting_permission_catalog(code,module,label,description,sort_order) VALUES
('contacts.view','Contacts','View contacts','View contact, lawyer and brokerage directories.',45),
('contacts.manage','Contacts','Manage contacts','Create and edit contacts, lawyers and external brokerage directories.',46),
('lawyers.view','Contacts','View lawyers','View law firms and lawyer contacts.',47),
('brokerages.view','Contacts','View brokerages','View external brokerage and co-operating agent records.',48)
ON CONFLICT(code) DO UPDATE SET module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;

INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at)
SELECT roles.role, perms.code, roles.allowed, 'ALL', now()
FROM (VALUES ('SUPERADMIN',true),('ADMIN',true),('MANAGER',false),('STAFF',false),('ACCOUNTANT',false),('VIEWER',false),('AGENT',false)) AS roles(role,allowed)
CROSS JOIN (VALUES ('contacts.view'),('contacts.manage'),('lawyers.view'),('brokerages.view')) AS perms(code)
ON CONFLICT(role,permission_code) DO NOTHING;
UPDATE public.dv_accounting_role_permission_rules SET allowed=true WHERE role='MANAGER' AND permission_code='contacts.view';
UPDATE public.dv_accounting_role_permission_rules SET allowed=true WHERE role='ACCOUNTANT' AND permission_code IN ('contacts.view','lawyers.view','brokerages.view');

CREATE OR REPLACE FUNCTION public.dv_accounting_can_manage_user_access()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.dv_accounting_current_user_role()='SUPERADMIN'
    OR public.dv_accounting_has_permission_all_scope('settings.users.manage')
    OR public.dv_accounting_has_permission_all_scope('settings.roles.manage')
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_is_trade_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT coalesce(public.dv_accounting_has_permission_all_scope('transactions.edit'),false)
$function$;

DO $policies$
DECLARE item record; old_policy record;
BEGIN
  FOR item IN SELECT * FROM (VALUES
('dv_accounting_agent_bank_details','public.dv_accounting_has_any_permission_all_scope(ARRAY[''settings.banking.manage'',''commission.issue''])','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')'),
('dv_accounting_agent_fee_rules','public.dv_accounting_has_any_permission_all_scope(ARRAY[''fees.view'',''agents.view''])','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')'),
('dv_accounting_agent_fee_settings','public.dv_accounting_has_any_permission_all_scope(ARRAY[''fees.view'',''agents.view''])','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')'),
('dv_accounting_agent_memberships','public.dv_accounting_has_permission_all_scope(''agents.view'')','public.dv_accounting_has_permission_all_scope(''agents.edit'')','public.dv_accounting_has_permission_all_scope(''agents.edit'')','public.dv_accounting_has_permission_all_scope(''agents.edit'')'),
('dv_accounting_agents','(public.dv_accounting_has_permission_all_scope(''agents.view'') OR lower(btrim(coalesce(email,'''')))=lower(btrim(coalesce(auth.jwt()->>''email'',''''))))','public.dv_accounting_has_permission_all_scope(''agents.create'')','public.dv_accounting_has_permission_all_scope(''agents.edit'')','public.dv_accounting_has_permission_all_scope(''agents.delete'')'),
('dv_accounting_amortization_schedules','public.dv_accounting_has_any_permission_all_scope(ARRAY[''expenses.view'',''reports.view''])','public.dv_accounting_has_permission_all_scope(''expenses.create'')','public.dv_accounting_has_permission_all_scope(''expenses.edit'')','public.dv_accounting_has_permission_all_scope(''expenses.edit'')'),
('dv_accounting_bank_accounts','public.dv_accounting_has_permission_all_scope(''banking.view'')','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')','public.dv_accounting_has_permission_all_scope(''settings.banking.manage'')'),
('dv_accounting_bank_transactions','public.dv_accounting_has_permission_all_scope(''banking.view'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')'),
('dv_accounting_branches','public.dv_accounting_has_any_permission_all_scope(ARRAY[''agents.view'',''staff.view'',''settings.company.manage''])','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_categories','public.dv_accounting_has_any_permission_all_scope(ARRAY[''expenses.view'',''expenses.create'',''reports.view'',''settings.company.manage''])','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_commission_charges','public.dv_accounting_has_permission_all_scope(''commission.view'')','public.dv_accounting_has_any_permission_all_scope(ARRAY[''fees.manage'',''commission.issue''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''fees.manage'',''commission.issue''])','public.dv_accounting_has_permission_all_scope(''commission.issue'')'),
('dv_accounting_commission_cheques','public.dv_accounting_has_permission_all_scope(''commission.view'')','public.dv_accounting_has_permission_all_scope(''commission.issue'')','public.dv_accounting_has_permission_all_scope(''commission.issue'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_commissions','public.dv_accounting_has_permission_all_scope(''commission.view'')','public.dv_accounting_has_permission_all_scope(''commission.issue'')','public.dv_accounting_has_permission_all_scope(''commission.issue'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_companies','public.dv_accounting_has_any_permission_all_scope(ARRAY[''dashboard.view'',''transactions.view'',''transactions.create'',''agents.view'',''staff.view'',''expenses.view'',''banking.view'',''commission.view'',''reports.view'',''settings.view'',''settings.company.manage''])','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_contacts','public.dv_accounting_has_any_permission_all_scope(ARRAY[''contacts.view'',''expenses.view'',''transactions.view''])','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')'),
('dv_accounting_employees','public.dv_accounting_has_any_permission_all_scope(ARRAY[''staff.view'',''payroll.view''])','public.dv_accounting_has_permission_all_scope(''staff.create'')','public.dv_accounting_has_permission_all_scope(''staff.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_expense_categories','public.dv_accounting_has_any_permission_all_scope(ARRAY[''expenses.view'',''expenses.create''])','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_expenses','public.dv_accounting_has_permission_all_scope(''expenses.view'')','public.dv_accounting_has_permission_all_scope(''expenses.create'')','public.dv_accounting_has_permission_all_scope(''expenses.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_external_brokerage_agents','public.dv_accounting_has_any_permission_all_scope(ARRAY[''brokerages.view'',''transactions.view''])','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')'),
('dv_accounting_external_brokerages','public.dv_accounting_has_any_permission_all_scope(ARRAY[''brokerages.view'',''transactions.view''])','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')'),
('dv_accounting_fee_plans','public.dv_accounting_has_permission_all_scope(''fees.view'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')'),
('dv_accounting_fixed_assets','public.dv_accounting_has_any_permission_all_scope(ARRAY[''expenses.view'',''reports.view''])','public.dv_accounting_has_permission_all_scope(''expenses.create'')','public.dv_accounting_has_permission_all_scope(''expenses.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_gl_accounts','public.dv_accounting_has_permission_all_scope(''reports.view'')','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_hst_adjustments','public.dv_accounting_has_permission_all_scope(''tax.view'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')'),
('dv_accounting_hst_periods','public.dv_accounting_has_permission_all_scope(''tax.view'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')','public.dv_accounting_has_permission_all_scope(''tax.manage'')'),
('dv_accounting_income_categories','public.dv_accounting_has_any_permission_all_scope(ARRAY[''reports.view'',''settings.company.manage''])','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_journal_entries','public.dv_accounting_has_any_permission_all_scope(ARRAY[''reports.view'',''compliance.view''])','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_journal_lines','public.dv_accounting_has_any_permission_all_scope(ARRAY[''reports.view'',''compliance.view''])','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN''','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_law_firms','public.dv_accounting_has_any_permission_all_scope(ARRAY[''lawyers.view'',''contacts.view''])','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')','public.dv_accounting_has_permission_all_scope(''contacts.manage'')'),
('dv_accounting_listings','public.dv_accounting_has_any_permission_all_scope(ARRAY[''agents.view'',''transactions.view''])','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_month_end','public.dv_accounting_has_permission_all_scope(''compliance.view'')','public.dv_accounting_has_permission_all_scope(''compliance.close'')','public.dv_accounting_has_permission_all_scope(''compliance.close'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_payroll_lines','public.dv_accounting_has_permission_all_scope(''payroll.view'')','public.dv_accounting_has_permission_all_scope(''payroll.calculate'')','public.dv_accounting_has_any_permission_all_scope(ARRAY[''payroll.calculate'',''payroll.approve'',''payroll.post''])','public.dv_accounting_has_permission_all_scope(''payroll.post'')'),
('dv_accounting_payroll_remittances','public.dv_accounting_has_permission_all_scope(''payroll.view'')','public.dv_accounting_has_permission_all_scope(''payroll.remit'')','public.dv_accounting_has_permission_all_scope(''payroll.remit'')','public.dv_accounting_has_permission_all_scope(''payroll.remit'')'),
('dv_accounting_payroll_runs','public.dv_accounting_has_permission_all_scope(''payroll.view'')','public.dv_accounting_has_permission_all_scope(''payroll.calculate'')','public.dv_accounting_has_any_permission_all_scope(ARRAY[''payroll.calculate'',''payroll.approve'',''payroll.post''])','public.dv_accounting_has_permission_all_scope(''payroll.post'')'),
('dv_accounting_real_estate_boards','public.dv_accounting_has_permission_all_scope(''agents.view'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')','public.dv_accounting_has_permission_all_scope(''settings.company.manage'')'),
('dv_accounting_reconciliations','public.dv_accounting_has_permission_all_scope(''banking.view'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')'),
('dv_accounting_recurring_fee_rules','public.dv_accounting_has_permission_all_scope(''fees.view'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')'),
('dv_accounting_recurring_fee_runs','public.dv_accounting_has_permission_all_scope(''fees.view'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')','public.dv_accounting_has_permission_all_scope(''fees.manage'')'),
('dv_accounting_settings','((key=''DASHBOARD_WIDGETS'' AND public.dv_accounting_has_permission_all_scope(''dashboard.view'')) OR (key=''PAYROLL_REMITTER_FREQUENCY'' AND public.dv_accounting_has_any_permission_all_scope(ARRAY[''payroll.view'',''payroll.remit'',''settings.company.manage''])) OR (key IN (''TRADE_DOCUMENT_REQUIREMENTS'',''LISTING_DOCUMENT_REQUIREMENTS'') AND public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.view'',''agents.view'',''settings.company.manage''])) OR public.dv_accounting_has_any_permission_all_scope(ARRAY[''settings.company.manage'',''settings.banking.manage'']))','((key=''PAYROLL_REMITTER_FREQUENCY'' AND public.dv_accounting_has_permission_all_scope(''payroll.remit'')) OR (key IN (''TRADE_DOCUMENT_REQUIREMENTS'',''LISTING_DOCUMENT_REQUIREMENTS'') AND public.dv_accounting_current_user_role() = ''SUPERADMIN'') OR public.dv_accounting_has_permission_all_scope(''settings.company.manage''))','((key=''PAYROLL_REMITTER_FREQUENCY'' AND public.dv_accounting_has_permission_all_scope(''payroll.remit'')) OR (key IN (''TRADE_DOCUMENT_REQUIREMENTS'',''LISTING_DOCUMENT_REQUIREMENTS'') AND public.dv_accounting_current_user_role() = ''SUPERADMIN'') OR public.dv_accounting_has_permission_all_scope(''settings.company.manage''))','((key IN (''TRADE_DOCUMENT_REQUIREMENTS'',''LISTING_DOCUMENT_REQUIREMENTS'') AND public.dv_accounting_current_user_role() = ''SUPERADMIN'') OR public.dv_accounting_has_permission_all_scope(''settings.company.manage''))'),
('dv_accounting_time_entries','public.dv_accounting_has_any_permission_all_scope(ARRAY[''staff.view'',''payroll.view''])','public.dv_accounting_has_permission_all_scope(''staff.hours.manage'')','public.dv_accounting_has_permission_all_scope(''staff.hours.manage'')','public.dv_accounting_has_permission_all_scope(''staff.hours.manage'')'),
('dv_accounting_transaction_agent_info','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.view'',''commission.view''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''commission.issue''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''commission.issue''])','public.dv_accounting_has_permission_all_scope(''commission.issue'')'),
('dv_accounting_transaction_commissions','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.view'',''commission.view''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''commission.issue''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''commission.issue''])','public.dv_accounting_has_permission_all_scope(''commission.issue'')'),
('dv_accounting_transaction_conditions','public.dv_accounting_has_permission_all_scope(''transactions.view'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')'),
('dv_accounting_transaction_outside_brokers','public.dv_accounting_has_permission_all_scope(''transactions.view'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')'),
('dv_accounting_transaction_people','public.dv_accounting_has_permission_all_scope(''transactions.view'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')'),
('dv_accounting_transaction_trust','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.view'',''banking.view''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''banking.reconcile''])','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.edit'',''banking.reconcile''])','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')'),
('dv_accounting_transactions','public.dv_accounting_has_any_permission_all_scope(ARRAY[''transactions.view'',''reports.view''])','public.dv_accounting_has_permission_all_scope(''transactions.create'')','public.dv_accounting_has_permission_all_scope(''transactions.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN'''),
('dv_accounting_trust_liabilities','public.dv_accounting_has_permission_all_scope(''banking.view'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')'),
('dv_accounting_trust_transactions','public.dv_accounting_has_permission_all_scope(''banking.view'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')','public.dv_accounting_has_permission_all_scope(''banking.reconcile'')'),
('dv_accounting_vendors','public.dv_accounting_has_permission_all_scope(''expenses.view'')','public.dv_accounting_has_permission_all_scope(''expenses.create'')','public.dv_accounting_has_permission_all_scope(''expenses.edit'')','public.dv_accounting_current_user_role() = ''SUPERADMIN''')
  ) AS x(table_name,select_expr,insert_expr,update_expr,delete_expr)
  LOOP
    FOR old_policy IN SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=item.table_name LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',old_policy.policyname,item.table_name);
    END LOOP;
    EXECUTE format('CREATE POLICY dv_permission_select ON public.%I FOR SELECT TO authenticated USING (%s)',item.table_name,item.select_expr);
    EXECUTE format('CREATE POLICY dv_permission_insert ON public.%I FOR INSERT TO authenticated WITH CHECK (%s)',item.table_name,item.insert_expr);
    EXECUTE format('CREATE POLICY dv_permission_update ON public.%I FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)',item.table_name,item.update_expr,item.update_expr);
    EXECUTE format('CREATE POLICY dv_permission_delete ON public.%I FOR DELETE TO authenticated USING (%s)',item.table_name,item.delete_expr);
  END LOOP;
END
$policies$;

DROP POLICY IF EXISTS "user permission overrides manage" ON public.dv_accounting_user_permission_overrides;
DROP POLICY IF EXISTS "user permission overrides read" ON public.dv_accounting_user_permission_overrides;
CREATE POLICY "user permission overrides read"
  ON public.dv_accounting_user_permission_overrides
  FOR SELECT TO authenticated
  USING (user_id=auth.uid() OR public.dv_accounting_has_permission_all_scope('settings.roles.manage'));
CREATE POLICY "user permission overrides manage"
  ON public.dv_accounting_user_permission_overrides
  FOR ALL TO authenticated
  USING (public.dv_accounting_current_user_role()='SUPERADMIN' OR public.dv_accounting_has_permission_all_scope('settings.roles.manage'))
  WITH CHECK (public.dv_accounting_current_user_role()='SUPERADMIN' OR public.dv_accounting_has_permission_all_scope('settings.roles.manage'));


CREATE OR REPLACE FUNCTION public.dv_accounting_approve_transaction_commission(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.dv_accounting_transactions%rowtype;
BEGIN
  IF NOT (public.dv_accounting_has_permission_all_scope('commission.preview')) THEN RAISE EXCEPTION 'You do not have permission to approve transaction commissions'; END IF;
  select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
  if not found then raise exception 'Transaction not found'; end if;
  if t.status in ('FINALIZED','CLOSED') then raise exception 'Finalized or closed transaction commission cannot be changed'; end if;
  if coalesce(t.gross_commission,0)<=0 and coalesce(t.agent_commission,0)<=0 then
    raise exception 'Enter and verify the commission amount before approval';
  end if;
  update public.dv_accounting_transactions
  set commission_approved=true,
      commission_approved_at=coalesce(commission_approved_at,now()),
      commission_approved_amount=coalesce(t.gross_commission,0),
      commission_approved_agent_payable=coalesce(t.agent_commission,0)
  where id=t.id;
  return jsonb_build_object('ok',true,'transaction_id',t.id,'approved_amount',coalesce(t.gross_commission,0),'agent_payable',coalesce(t.agent_commission,0));
end $function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_clear_user_permission(p_user_id uuid, p_permission_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND public.dv_accounting_has_permission_all_scope('settings.roles.manage') IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage user permissions';
  END IF;
  IF p_user_id IS NULL OR p_user_id=auth.uid() THEN RAISE EXCEPTION 'Choose another user; changing your own overrides is not allowed'; END IF;
  DELETE FROM public.dv_accounting_user_permission_overrides
  WHERE user_id=p_user_id AND permission_code=p_permission_code;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_finalize_transaction(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 t public.dv_accounting_transactions%rowtype;
 company uuid;
 je uuid;
 ar uuid; rev uuid; hst uuid; agent_exp uuid; agent_pay uuid;
 coop_exp uuid; coop_pay uuid; hst_rec uuid; trust_bank_gl uuid; trust_liability uuid;
 agent_amt numeric(14,2);
 is_broker_100 boolean := false;
 c record;
 tr record;
 coop_hst numeric(14,2);
BEGIN
  IF NOT (public.dv_accounting_has_permission_all_scope('transactions.finalize')) THEN RAISE EXCEPTION 'You do not have permission to finalize transactions'; END IF;
 select * into t from public.dv_accounting_transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if t.status='FINALIZED' then return jsonb_build_object('ok',true,'message','Already finalized'); end if;
 company:=t.company_id;
 if company is null then
   select id into company from public.dv_accounting_companies order by created_at limit 1;
   if company is null then raise exception 'Create a company in Settings before finalizing transactions'; end if;
   update public.dv_accounting_transactions set company_id=company where id=t.id;
 end if;

 insert into public.dv_accounting_gl_accounts(company_id,code,name,account_type)
 values
 (company,'1150','Commission Receivable','ASSET'),
 (company,'4000','Commission Revenue','REVENUE'),
 (company,'2400','HST Payable','LIABILITY'),
 (company,'5200','Agent Commission Expense','EXPENSE'),
 (company,'2200','Agent Commissions Payable','LIABILITY'),
 (company,'2100','Co-operating Brokerage Payable','LIABILITY'),
 (company,'5250','Co-operating Brokerage Commission Expense','EXPENSE'),
 (company,'1180','HST Recoverable / Input Tax Credits','ASSET'),
 (company,'1015','Real Estate Trust Bank','ASSET'),
 (company,'2300','Real Estate Trust Liabilities','LIABILITY')
 on conflict(company_id,code) do nothing;

 select id into ar from public.dv_accounting_gl_accounts where company_id=company and code='1150';
 select id into rev from public.dv_accounting_gl_accounts where company_id=company and code='4000';
 select id into hst from public.dv_accounting_gl_accounts where company_id=company and code='2400';
 select id into agent_exp from public.dv_accounting_gl_accounts where company_id=company and code='5200';
 select id into agent_pay from public.dv_accounting_gl_accounts where company_id=company and code='2200';
 select id into coop_exp from public.dv_accounting_gl_accounts where company_id=company and code='5250';
 select id into coop_pay from public.dv_accounting_gl_accounts where company_id=company and code='2100';
 select id into hst_rec from public.dv_accounting_gl_accounts where company_id=company and code='1180';
 select id into trust_bank_gl from public.dv_accounting_gl_accounts where company_id=company and code='1015';
 select id into trust_liability from public.dv_accounting_gl_accounts where company_id=company and code='2300';

 IF t.agent_id IS NOT NULL THEN
   SELECT EXISTS(
     SELECT 1
     FROM public.dv_accounting_agent_fee_settings fs
     JOIN public.dv_accounting_fee_plans fp ON fp.id=fs.fee_plan_id
     WHERE fs.agent_id=t.agent_id
       AND regexp_replace(lower(coalesce(fp.name,'')), '[^a-z0-9]', '', 'g') LIKE 'broker100%'
   ) INTO is_broker_100;
 END IF;
 agent_amt:=CASE WHEN is_broker_100 THEN 0 ELSE coalesce(t.agent_commission,0) END;
 insert into public.dv_accounting_journal_entries(company_id,entry_date,source_type,source_id,memo)
 values(company,coalesce(t.close_date,t.transaction_date,current_date),'TRANSACTION',t.id,'Finalize real estate transaction') returning id into je;

 -- Brokerage commission receivable and revenue, plus HST collected.
 if coalesce(t.gross_commission,0)<>0 or coalesce(t.hst_amount,0)<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,ar,coalesce(t.gross_commission,0)+coalesce(t.hst_amount,0),0),
         (je,rev,0,coalesce(t.gross_commission,0));
   if coalesce(t.hst_amount,0)<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,hst,0,t.hst_amount);
   end if;
 end if;

 -- Agent commission expense and amount due to the agent.
 if agent_amt<>0 then
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,agent_exp,agent_amt,0),(je,agent_pay,0,agent_amt);
 end if;

 -- Co-operating brokerage commissions: expense + any eligible HST ITC, offset by A/P.
 for c in
   select tc.*, coalesce(eb.charges_hst,true) as brokerage_charges_hst
   from public.dv_accounting_transaction_commissions tc
   left join public.dv_accounting_external_brokerages eb on eb.id=tc.brokerage_id
   where tc.transaction_id=t.id and tc.settlement_direction='PAYABLE'
 loop
   coop_hst:=case when c.brokerage_charges_hst then coalesce(c.hst_amount,0) else 0 end;
   if coalesce(c.amount,0)+coop_hst<>0 then
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_exp,coalesce(c.amount,0),0);
     if coop_hst<>0 then
       insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
       values(je,hst_rec,coop_hst,0);
     end if;
     insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
     values(je,coop_pay,0,coalesce(c.amount,0)+coop_hst);
   end if;
 end loop;

 -- Only post a trust receipt when Dream Valley actually holds and has received the deposit.
 select * into tr
 from public.dv_accounting_transaction_trust
 where transaction_id=t.id and we_hold_deposit='YES' and received='YES' and amount>0
 order by created_at desc limit 1;
 if found then
   if tr.trust_bank_account_id is null then
     raise exception 'Select the Real Estate Trust bank account before finalizing a received deposit';
   end if;
   if not exists(select 1 from public.dv_accounting_bank_accounts b where b.id=tr.trust_bank_account_id and b.account_type='REAL_ESTATE_TRUST' and b.active=true) then
     raise exception 'The selected deposit account must be an active Real Estate Trust account';
   end if;
   insert into public.dv_accounting_journal_lines(journal_entry_id,gl_account_id,debit,credit)
   values(je,trust_bank_gl,tr.amount,0),(je,trust_liability,0,tr.amount);
 end if;

 update public.dv_accounting_transactions
 set status='FINALIZED', finalized_at=now(), finalized_date=coalesce(finalized_date,current_date), company_id=company,
     agent_commission=agent_amt,
     commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false) THEN agent_amt ELSE commission_approved_agent_payable END
 where id=t.id;
 return jsonb_build_object('ok',true,'journal_entry_id',je,'agent_commission',agent_amt);
end $function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_issue_commission_cheque(p_commission_id uuid, p_cheque_number text DEFAULT NULL::text, p_cheque_date date DEFAULT CURRENT_DATE, p_adjustment numeric DEFAULT 0, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c public.dv_accounting_commissions%rowtype;
  t public.dv_accounting_transactions%rowtype;
  agent public.dv_accounting_agents%rowtype;
  calc jsonb;
  cheque_id uuid;
  gross_amt numeric(14,2);
  agent_share numeric(14,2);
  transaction_fees numeric(14,2);
  outstanding_fees numeric(14,2);
  total_fees numeric(14,2);
  net_agent_before_hst numeric(14,2);
  hst_rate numeric(6,3) := 13;
  agent_hst numeric(14,2) := 0;
  client_hst numeric(14,2) := 0;
  brokerage_hst numeric(14,2) := 0;
  ai record;
  lead_to_restore numeric(14,2) := 0;
BEGIN
  IF NOT (public.dv_accounting_has_permission_all_scope('commission.issue')) THEN RAISE EXCEPTION 'You do not have permission to issue commission cheques'; END IF;
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Commission record not found'; END IF;
  IF c.status='PAID' THEN RAISE EXCEPTION 'Commission has already been paid'; END IF;
  SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transaction not found'; END IF;

  -- Last-line safeguard: restore a saved lead deduction for non-lead transactions
  -- before issuing payment. The condition prevents a second restoration.
  IF NOT COALESCE(t.is_brokerage_lead,false) THEN
    SELECT lead_fee, net_payable INTO ai
    FROM public.dv_accounting_transaction_agent_info
    WHERE transaction_id=c.transaction_id
    LIMIT 1;
    lead_to_restore:=GREATEST(COALESCE(ai.lead_fee,0),0);
    IF lead_to_restore>0
       AND ROUND(COALESCE(c.agent_share,0),2) <= ROUND(COALESCE(ai.net_payable,c.agent_share,0),2)+0.01 THEN
      UPDATE public.dv_accounting_commissions
      SET agent_share=ROUND(COALESCE(agent_share,0)+lead_to_restore,2),
          brokerage_share=GREATEST(ROUND(COALESCE(gross_commission,0)-(COALESCE(agent_share,0)+lead_to_restore),2),0)
      WHERE id=c.id;
      UPDATE public.dv_accounting_transactions
      SET agent_commission=ROUND(COALESCE(agent_commission,0)+lead_to_restore,2),
          commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
            THEN ROUND(COALESCE(commission_approved_agent_payable,0)+lead_to_restore,2)
            ELSE commission_approved_agent_payable END
      WHERE id=c.transaction_id;
      UPDATE public.dv_accounting_transaction_agent_info
      SET lead_fee=0, lead_fee_applies=false,
          net_payable=ROUND(COALESCE(net_payable,0)+lead_to_restore,2)
      WHERE transaction_id=c.transaction_id;
      SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;
      SELECT * INTO t FROM public.dv_accounting_transactions WHERE id=c.transaction_id;
    END IF;
  END IF;

  SELECT * INTO agent FROM public.dv_accounting_agents WHERE id=c.agent_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Agent not found'; END IF;

  gross_amt:=COALESCE(c.gross_commission,t.gross_commission,0);
  calc:=public.dv_accounting_calculate_commission_fees(c.agent_id,c.transaction_id,gross_amt,COALESCE(t.transaction_date,p_cheque_date));
  transaction_fees:=ROUND(COALESCE((calc->>'admin_fee')::numeric,0)+COALESCE((calc->>'lead_fee')::numeric,0)+COALESCE((calc->>'desk_fee')::numeric,0),2);

  -- Calculate agent payable from GCI less applicable transaction fees; GCI is already the agent gross commission.
  -- This prevents a stale approved amount from preserving an incorrect lead deduction
  -- or omitting the configured admin fee.
  -- Respect the calculated plan split; gross commission is not automatically the agent's share.
  agent_share:=GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0);

  UPDATE public.dv_accounting_commissions
  SET agent_share=GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0),
      brokerage_share=GREATEST(ROUND(gross_amt-GREATEST(ROUND(COALESCE((calc->>'agent_share')::numeric,0)-transaction_fees,2),0),2),0)
  WHERE id=c.id;
  UPDATE public.dv_accounting_transactions
  SET agent_commission=agent_share,
      commission_approved_agent_payable=CASE WHEN COALESCE(commission_approved,false)
        THEN agent_share ELSE commission_approved_agent_payable END
  WHERE id=t.id;
  SELECT * INTO c FROM public.dv_accounting_commissions WHERE id=p_commission_id;

  SELECT COALESCE(SUM(amount),0) INTO outstanding_fees
  FROM public.dv_accounting_commission_charges
  WHERE agent_id=c.agent_id AND status='OPEN' AND applied_to_cheque_id IS NULL
    AND COALESCE(commission_id::text,'')<>c.id::text;
  total_fees:=ROUND(outstanding_fees,2);
  net_agent_before_hst:=GREATEST(agent_share-total_fees,0);

  IF NULLIF(BTRIM(COALESCE(agent.hst_number,'')),'') IS NOT NULL THEN
    agent_hst:=ROUND(net_agent_before_hst*hst_rate/100,2);
  END IF;
  client_hst:=CASE WHEN COALESCE(t.hst_amount,0)>0 THEN ROUND(t.hst_amount,2) ELSE ROUND(gross_amt*hst_rate/100,2) END;
  brokerage_hst:=GREATEST(client_hst-agent_hst,0);

  INSERT INTO public.dv_accounting_commission_cheques(
    company_id,agent_id,commission_id,cheque_number,cheque_date,gross_commission,agent_share,total_fees,adjustments,status,issued_at,notes,
    agent_hst_number,agent_hst_rate,agent_hst_amount,brokerage_hst_amount,client_hst_amount
  ) VALUES(
    t.company_id,c.agent_id,c.id,p_cheque_number,p_cheque_date,gross_amt,agent_share,total_fees,COALESCE(p_adjustment,0),'ISSUED',now(),p_notes,
    NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),hst_rate,agent_hst,brokerage_hst,client_hst
  ) RETURNING id INTO cheque_id;

  INSERT INTO public.dv_accounting_commission_charges(
    commission_id,transaction_id,agent_id,charge_type,description,amount,source_rule_id
  )
  SELECT c.id,c.transaction_id,c.agent_id,x.charge_type,x.description,x.amount,
    CASE WHEN x.charge_type IN ('ADMIN_FEE','LEAD_FEE') THEN (calc->>'fee_rule_id')::uuid ELSE NULL END
  FROM jsonb_to_recordset(jsonb_build_array(
    jsonb_build_object('charge_type','ADMIN_FEE','description','Transaction admin fee','amount',0),
    jsonb_build_object('charge_type','LEAD_FEE','description','Transaction lead fee','amount',0)
  )) AS x(charge_type text,description text,amount numeric)
  WHERE x.amount>0;

  UPDATE public.dv_accounting_commissions SET status='PAID',paid_date=p_cheque_date WHERE id=c.id;

  RETURN jsonb_build_object(
    'cheque_id',cheque_id,'commission_id',c.id,'agent_share',agent_share,
    'agent_net_before_hst',net_agent_before_hst,'agent_hst_number',NULLIF(BTRIM(COALESCE(agent.hst_number,'')),''),
    'agent_hst_rate',hst_rate,'agent_hst_amount',agent_hst,'brokerage_hst_amount',brokerage_hst,'client_hst_amount',client_hst,
    'total_fees',total_fees,'transaction_fees',transaction_fees,'lead_fee_amount',COALESCE((calc->>'lead_fee')::numeric,0),
    'net_amount',net_agent_before_hst+COALESCE(p_adjustment,0)+agent_hst,'calculation',calc
  );
END $function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_role_permission(p_role text, p_permission_code text, p_allowed boolean, p_scope text DEFAULT 'ALL'::text)
 RETURNS dv_accounting_role_permission_rules
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE result public.dv_accounting_role_permission_rules;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND public.dv_accounting_has_permission_all_scope('settings.roles.manage') IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage role templates';
  END IF;
  IF upper(p_role) NOT IN ('SUPERADMIN','ADMIN','MANAGER','STAFF','ACCOUNTANT','VIEWER','AGENT') THEN
    RAISE EXCEPTION 'Invalid role';
  END IF;
  IF p_scope NOT IN ('ALL','BRANCH','OWN') THEN RAISE EXCEPTION 'Invalid access scope'; END IF;
  IF upper(p_role)='SUPERADMIN' AND p_allowed=false THEN RAISE EXCEPTION 'Super Admin permissions cannot be removed'; END IF;
  INSERT INTO public.dv_accounting_role_permission_rules(role,permission_code,allowed,access_scope,updated_at,updated_by)
  VALUES(upper(p_role),p_permission_code,p_allowed,p_scope,now(),auth.uid())
  ON CONFLICT(role,permission_code) DO UPDATE
    SET allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
  RETURNING * INTO result;
  RETURN result;
END
$function$;

CREATE OR REPLACE FUNCTION public.dv_accounting_set_user_permission(p_user_id uuid, p_permission_code text, p_allowed boolean, p_scope text DEFAULT 'ALL'::text)
 RETURNS dv_accounting_user_permission_overrides
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE result public.dv_accounting_user_permission_overrides;
BEGIN
  IF public.dv_accounting_current_user_role() <> 'SUPERADMIN'
     AND public.dv_accounting_has_permission_all_scope('settings.roles.manage') IS NOT TRUE THEN
    RAISE EXCEPTION 'You do not have permission to manage user permissions';
  END IF;
  IF p_user_id IS NULL OR p_user_id=auth.uid() THEN RAISE EXCEPTION 'Choose another user; changing your own overrides is not allowed'; END IF;
  IF p_scope NOT IN ('ALL','BRANCH','OWN') THEN RAISE EXCEPTION 'Invalid access scope'; END IF;
  IF p_permission_code='settings.roles.manage' AND p_allowed=true AND p_user_id IS NULL THEN RAISE EXCEPTION 'Invalid user'; END IF;
  INSERT INTO public.dv_accounting_user_permission_overrides(user_id,permission_code,allowed,access_scope,updated_at,updated_by)
  VALUES(p_user_id,p_permission_code,p_allowed,p_scope,now(),auth.uid())
  ON CONFLICT(user_id,permission_code) DO UPDATE
    SET allowed=excluded.allowed,access_scope=excluded.access_scope,updated_at=now(),updated_by=auth.uid()
  RETURNING * INTO result;
  RETURN result;
END
$function$;
