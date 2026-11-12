-- Allow active ADMIN and SUPERADMIN users to upload transaction archive
-- documents, including after a trade is closed and paid. Preserve uploader
-- identity checks and restrict storage objects to the transaction archive path.

drop policy if exists "transaction documents admin insert"
  on public.dv_accounting_transaction_documents;

create policy "transaction documents admin insert"
  on public.dv_accounting_transaction_documents
  for insert
  to authenticated
  with check (
    auth.uid() is not null
    and uploaded_by = auth.uid()
    and public.dv_accounting_current_user_role() in ('ADMIN','SUPERADMIN','SUPERADMINISTRATOR')
  );

drop policy if exists "transaction archive storage insert"
  on storage.objects;

create policy "transaction archive storage insert"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'dv-trade-documents'
    and (storage.foldername(name))[1] = 'transactions'
    and auth.uid() is not null
    and public.dv_accounting_current_user_role() in ('ADMIN','SUPERADMIN','SUPERADMINISTRATOR')
  );
