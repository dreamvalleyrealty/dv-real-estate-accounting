-- Dedicated permission for permanently deleting draft listing submissions.
-- Apply this migration to the connected Supabase project after review.

insert into public.dv_accounting_permission_catalog (code, module, label, description)
values (
  'listings.drafts.delete',
  'Listings',
  'Delete Draft Listings',
  'Permanently delete listing submissions only while their status is DRAFT, including their uploaded listing documents.'
)
on conflict (code) do update
set module = excluded.module,
    label = excluded.label,
    description = excluded.description;
