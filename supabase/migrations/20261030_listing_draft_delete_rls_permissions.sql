-- Allow staff with the dedicated ALL-scope permission to delete DRAFT listings and their attached records/files.
drop policy if exists "listing draft delete by permission" on public.dv_accounting_listing_submissions;
create policy "listing draft delete by permission"
on public.dv_accounting_listing_submissions
for delete
to authenticated
using (
  status = 'DRAFT'
  and public.dv_accounting_has_permission_all_scope('listings.drafts.delete')
);

drop policy if exists "listing draft documents delete by permission" on public.dv_accounting_listing_documents;
create policy "listing draft documents delete by permission"
on public.dv_accounting_listing_documents
for delete
to authenticated
using (
  public.dv_accounting_has_permission_all_scope('listings.drafts.delete')
  and exists (
    select 1
    from public.dv_accounting_listing_submissions s
    where s.id = dv_accounting_listing_documents.listing_id
      and s.status = 'DRAFT'
  )
);

drop policy if exists "listing draft storage delete by permission" on storage.objects;
create policy "listing draft storage delete by permission"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'dv-trade-documents'
  and (storage.foldername(name))[1] = 'listings'
  and public.dv_accounting_has_permission_all_scope('listings.drafts.delete')
);
