-- Add a dedicated permission for deleting listing documents.
insert into public.dv_accounting_permission_catalog (code, module, label, description, sort_order)
values (
  'listings.documents.delete',
  'Listings',
  'Delete listing documents',
  'Allows deleting uploaded listing documents from the listing Documents tab. Requires All records scope.',
  90
)
on conflict (code) do update
set module = excluded.module,
    label = excluded.label,
    description = excluded.description;
