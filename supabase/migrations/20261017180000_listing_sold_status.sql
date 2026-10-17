-- Permit linked listings to move into the Sold bucket when the associated trade becomes firm.
alter table public.dv_accounting_listing_submissions
  drop constraint if exists dv_accounting_listing_submissions_status_check;

alter table public.dv_accounting_listing_submissions
  add constraint dv_accounting_listing_submissions_status_check
  check (status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED','PUBLISHED','SOLD'));
