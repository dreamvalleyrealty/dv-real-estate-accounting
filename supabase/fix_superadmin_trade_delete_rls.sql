-- Fix Super Admin deletion permissions for agent trade submissions.
-- Apply this script in Supabase SQL Editor for the Production project.
-- This uses trusted app_metadata only; user_metadata is user-editable and must not grant admin privileges.

create policy "dv_superadmin_delete_trade_submissions"
on public.dv_accounting_agent_trade_submissions
for delete
to authenticated
using (upper(coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '')) = 'SUPERADMIN');

create policy "dv_superadmin_delete_trade_documents"
on public.dv_accounting_agent_trade_documents
for delete
to authenticated
using (upper(coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '')) = 'SUPERADMIN');

create policy "dv_superadmin_delete_trade_storage_objects"
on storage.objects
for delete
to authenticated
using (bucket_id = 'dv-trade-documents' and upper(coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '')) = 'SUPERADMIN');

-- These are permissive policies and do not replace existing SELECT/INSERT/UPDATE policies.
-- If a policy with one of these names already exists, PostgreSQL will report a duplicate;
-- in that case inspect it rather than dropping unknown production policies.