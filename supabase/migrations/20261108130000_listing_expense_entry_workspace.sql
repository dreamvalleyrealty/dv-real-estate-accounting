-- Allow management to record listing expenses directly from Listing Details,
-- including before a listing is approved or a transaction is closed.
-- This is operational expense capture only; it does not post accounting entries.

alter table public.dv_listing_expenses
  alter column supplier_contact_id drop not null,
  add column if not exists supplier_name text,
  add column if not exists receipt_storage_path text,
  add column if not exists receipt_file_name text;

create index if not exists dv_listing_expenses_listing_created_idx
  on public.dv_listing_expenses (listing_id, created_at);

drop policy if exists dv_listing_expense_receipts_management_read on storage.objects;
create policy dv_listing_expense_receipts_management_read
  on storage.objects for select to authenticated
  using (
    bucket_id = 'dv-trade-documents'
    and (storage.foldername(name))[1] = 'listing-expenses'
    and public.dv_is_management_user()
  );

drop policy if exists dv_listing_expense_receipts_management_insert on storage.objects;
create policy dv_listing_expense_receipts_management_insert
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'dv-trade-documents'
    and (storage.foldername(name))[1] = 'listing-expenses'
    and public.dv_is_management_user()
  );

drop policy if exists dv_listing_expense_receipts_management_delete on storage.objects;
create policy dv_listing_expense_receipts_management_delete
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'dv-trade-documents'
    and (storage.foldername(name))[1] = 'listing-expenses'
    and public.dv_is_management_user()
  );

comment on column public.dv_listing_expenses.receipt_storage_path is
  'Private storage path for the supplier invoice or receipt supporting this listing expense.';
