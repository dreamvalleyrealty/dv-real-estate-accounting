-- Per-document approval controls for listing submissions.
alter table public.dv_accounting_listing_documents
  add column if not exists review_status text not null default 'PENDING',
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
  add column if not exists reviewed_at timestamptz;

alter table public.dv_accounting_listing_documents
  drop constraint if exists dv_accounting_listing_documents_review_status_check;
alter table public.dv_accounting_listing_documents
  add constraint dv_accounting_listing_documents_review_status_check
  check (review_status in ('PENDING','APPROVED','NOT_APPROVED'));

drop policy if exists "listing documents admin update" on public.dv_accounting_listing_documents;
create policy "listing documents admin update"
  on public.dv_accounting_listing_documents
  for update to authenticated
  using (public.dv_accounting_is_trade_admin())
  with check (public.dv_accounting_is_trade_admin());
