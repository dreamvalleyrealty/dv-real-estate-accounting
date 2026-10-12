-- Listing submission support for multiple representing agents and admin-created drafts.
alter table public.dv_accounting_listing_submissions
  add column if not exists additional_agent_ids jsonb not null default '[]'::jsonb;

drop policy if exists "listing submissions admin create" on public.dv_accounting_listing_submissions;
create policy "listing submissions admin create"
on public.dv_accounting_listing_submissions
for insert to authenticated
with check (public.dv_accounting_is_trade_admin());

