-- Connect the newly catalogued settings permissions to their existing protected data.
-- Every policy is additive: all existing role-based and owner-based policies remain intact.
CREATE POLICY "permissioned users view active sessions"
ON public.dv_accounting_active_sessions
FOR SELECT TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.security.manage'::text));

CREATE POLICY "permissioned users view audit log"
ON public.dv_accounting_audit_log
FOR SELECT TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.audit.view'::text));

CREATE POLICY "permissioned users view journal audit"
ON public.dv_accounting_journal_audit
FOR SELECT TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.audit.view'::text));

CREATE POLICY "permissioned users view review notification log"
ON public.dv_accounting_review_notification_log
FOR SELECT TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.notifications.manage'::text));

CREATE POLICY "permissioned users manage review notification recipients"
ON public.dv_accounting_review_notification_recipients
FOR ALL TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.notifications.manage'::text))
WITH CHECK (public.dv_accounting_has_permission_all_scope('settings.notifications.manage'::text));

CREATE POLICY "permissioned users manage review notification templates"
ON public.dv_accounting_review_notification_templates
FOR ALL TO authenticated
USING (public.dv_accounting_has_permission_all_scope('settings.notifications.manage'::text))
WITH CHECK (public.dv_accounting_has_permission_all_scope('settings.notifications.manage'::text));

-- The document settings screen stores several requirement lists in the settings table.
-- This additive policy permits users with the new document-settings permission to
-- read and maintain only those document-related keys.
CREATE POLICY "permissioned users read document requirement settings"
ON public.dv_accounting_settings
FOR SELECT TO authenticated
USING (
 key = ANY(ARRAY[
  'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
  'LISTING_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE',
  'TRADE_DOCUMENT_TYPES',
  'TRADE_REQUIRED_DOCUMENT_COUNTS',
  'TRADE_REQUIRED_DOCUMENT_TYPES',
  'TRANSACTION_ARCHIVE_DOCUMENT_CATEGORIES'
 ]::text[])
 AND public.dv_accounting_has_permission_all_scope('settings.documents.manage'::text)
);

CREATE POLICY "permissioned users insert document requirement settings"
ON public.dv_accounting_settings
FOR INSERT TO authenticated
WITH CHECK (
 key = ANY(ARRAY[
  'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
  'LISTING_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE',
  'TRADE_DOCUMENT_TYPES',
  'TRADE_REQUIRED_DOCUMENT_COUNTS',
  'TRADE_REQUIRED_DOCUMENT_TYPES',
  'TRANSACTION_ARCHIVE_DOCUMENT_CATEGORIES'
 ]::text[])
 AND public.dv_accounting_has_permission_all_scope('settings.documents.manage'::text)
);

CREATE POLICY "permissioned users update document requirement settings"
ON public.dv_accounting_settings
FOR UPDATE TO authenticated
USING (
 key = ANY(ARRAY[
  'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
  'LISTING_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE',
  'TRADE_DOCUMENT_TYPES',
  'TRADE_REQUIRED_DOCUMENT_COUNTS',
  'TRADE_REQUIRED_DOCUMENT_TYPES',
  'TRANSACTION_ARCHIVE_DOCUMENT_CATEGORIES'
 ]::text[])
 AND public.dv_accounting_has_permission_all_scope('settings.documents.manage'::text)
)
WITH CHECK (
 key = ANY(ARRAY[
  'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
  'LISTING_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE',
  'TRADE_DOCUMENT_TYPES',
  'TRADE_REQUIRED_DOCUMENT_COUNTS',
  'TRADE_REQUIRED_DOCUMENT_TYPES',
  'TRANSACTION_ARCHIVE_DOCUMENT_CATEGORIES'
 ]::text[])
 AND public.dv_accounting_has_permission_all_scope('settings.documents.manage'::text)
);

CREATE POLICY "permissioned users delete document requirement settings"
ON public.dv_accounting_settings
FOR DELETE TO authenticated
USING (
 key = ANY(ARRAY[
  'AGENT_PERSONNEL_DOCUMENT_REQUIREMENTS',
  'LISTING_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS',
  'TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE',
  'TRADE_DOCUMENT_TYPES',
  'TRADE_REQUIRED_DOCUMENT_COUNTS',
  'TRADE_REQUIRED_DOCUMENT_TYPES',
  'TRANSACTION_ARCHIVE_DOCUMENT_CATEGORIES'
 ]::text[])
 AND public.dv_accounting_has_permission_all_scope('settings.documents.manage'::text)
);
