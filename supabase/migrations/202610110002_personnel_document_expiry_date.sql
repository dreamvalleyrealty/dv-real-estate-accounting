alter table public.dv_accounting_personnel_documents
  add column if not exists expiry_date date;

comment on column public.dv_accounting_personnel_documents.expiry_date is
  'Expiry date for personnel documents such as government ID, RECO licence copies, and independent contractor agreements.';
