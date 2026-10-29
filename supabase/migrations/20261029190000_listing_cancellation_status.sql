-- Allow admin-approved seller cancellation documents to move listings into the Cancelled status.
alter table public.dv_accounting_listing_submissions
  drop constraint if exists dv_accounting_listing_submissions_status_check;

alter table public.dv_accounting_listing_submissions
  add constraint dv_accounting_listing_submissions_status_check
  check (status in ('DRAFT','SUBMITTED','NEEDS_CHANGES','APPROVED','APPROVED_WITH_CHANGES','PUBLISHED','SOLD','CANCELLED'));
