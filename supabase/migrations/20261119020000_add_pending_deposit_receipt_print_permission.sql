insert into public.dv_accounting_permission_catalog (code,module,label,description,sort_order)
values (
  'listings.deposit.receipt.print_pending',
  'Listings',
  'Print pending deposit receipts',
  'Allows printing a preliminary listing trust deposit receipt while it is awaiting Admin approval. Printed copies are clearly marked Pending Admin Approval.',
  117
)
on conflict (code) do update
set module=excluded.module,
    label=excluded.label,
    description=excluded.description,
    sort_order=excluded.sort_order;
