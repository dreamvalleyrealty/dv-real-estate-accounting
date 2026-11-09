alter table public.dv_accounting_listing_submissions
  add column if not exists seller_details jsonb not null default '{}'::jsonb;

comment on column public.dv_accounting_listing_submissions.seller_details is
  'Structured primary seller details, including individual or company identity and company representative.';
