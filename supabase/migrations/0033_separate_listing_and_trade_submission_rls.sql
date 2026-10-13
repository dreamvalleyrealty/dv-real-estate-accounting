create or replace function public.dv_accounting_is_listing_admin()
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.dv_accounting_has_permission_all_scope('transactions.edit'),false)
     or coalesce(public.dv_accounting_has_permission_all_scope('listings.manage'),false)
$$;

create or replace function public.dv_accounting_is_trade_submission_admin()
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.dv_accounting_has_permission_all_scope('transactions.edit'),false)
     or coalesce(public.dv_accounting_has_permission_all_scope('trade_submissions.manage'),false)
$$;

drop policy if exists "listing submissions admin read" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin read" on public.dv_accounting_listing_submissions for select using (public.dv_accounting_is_listing_admin());
drop policy if exists "listing submissions admin create" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin create" on public.dv_accounting_listing_submissions for insert with check (public.dv_accounting_is_listing_admin());
drop policy if exists "listing submissions admin update" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin update" on public.dv_accounting_listing_submissions for update using (public.dv_accounting_is_listing_admin()) with check (public.dv_accounting_is_listing_admin());

drop policy if exists "listing documents admin read" on public.dv_accounting_listing_documents;
create policy "listing documents admin read" on public.dv_accounting_listing_documents for select using (public.dv_accounting_is_listing_admin());
drop policy if exists "listing documents admin insert" on public.dv_accounting_listing_documents;
create policy "listing documents admin insert" on public.dv_accounting_listing_documents for insert with check (public.dv_accounting_is_listing_admin() and uploaded_by=auth.uid());
drop policy if exists "listing documents admin update" on public.dv_accounting_listing_documents;
create policy "listing documents admin update" on public.dv_accounting_listing_documents for update using (public.dv_accounting_is_listing_admin()) with check (public.dv_accounting_is_listing_admin());
drop policy if exists "listing documents admin delete" on public.dv_accounting_listing_documents;
create policy "listing documents admin delete" on public.dv_accounting_listing_documents for delete using (public.dv_accounting_is_listing_admin());

drop policy if exists "agent trade submission read" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission read" on public.dv_accounting_agent_trade_submissions for select using (submitted_by=auth.uid() or public.dv_accounting_is_trade_submission_admin());
drop policy if exists "agent trade submission update" on public.dv_accounting_agent_trade_submissions;
create policy "agent trade submission update" on public.dv_accounting_agent_trade_submissions for update using (((submitted_by=auth.uid()) and status in ('DRAFT','NEEDS_CHANGES')) or public.dv_accounting_is_trade_submission_admin()) with check (((submitted_by=auth.uid()) and status in ('DRAFT','NEEDS_CHANGES','SUBMITTED')) or public.dv_accounting_is_trade_submission_admin());

drop policy if exists "agent trade document read" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document read" on public.dv_accounting_agent_trade_documents for select using (public.dv_accounting_is_trade_submission_admin() or exists(select 1 from public.dv_accounting_agent_trade_submissions s where s.id=dv_accounting_agent_trade_documents.submission_id and s.submitted_by=auth.uid()));
drop policy if exists "agent trade document update" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document update" on public.dv_accounting_agent_trade_documents for update using (public.dv_accounting_is_trade_submission_admin()) with check (public.dv_accounting_is_trade_submission_admin());
drop policy if exists "agent trade document delete" on public.dv_accounting_agent_trade_documents;
create policy "agent trade document delete" on public.dv_accounting_agent_trade_documents for delete using (public.dv_accounting_is_trade_submission_admin() or exists(select 1 from public.dv_accounting_agent_trade_submissions s where s.id=dv_accounting_agent_trade_documents.submission_id and s.submitted_by=auth.uid() and s.status in ('DRAFT','NEEDS_CHANGES')));
