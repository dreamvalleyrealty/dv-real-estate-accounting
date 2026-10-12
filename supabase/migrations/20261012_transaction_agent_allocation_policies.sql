-- Permit trade administrators to maintain transaction agent allocation records.
alter table public.dv_accounting_transaction_agents enable row level security;
drop policy if exists "transaction agents admin read" on public.dv_accounting_transaction_agents;
create policy "transaction agents admin read" on public.dv_accounting_transaction_agents for select to authenticated using (public.dv_accounting_is_trade_admin());
drop policy if exists "transaction agents admin insert" on public.dv_accounting_transaction_agents;
create policy "transaction agents admin insert" on public.dv_accounting_transaction_agents for insert to authenticated with check (public.dv_accounting_is_trade_admin());
drop policy if exists "transaction agents admin update" on public.dv_accounting_transaction_agents;
create policy "transaction agents admin update" on public.dv_accounting_transaction_agents for update to authenticated using (public.dv_accounting_is_trade_admin()) with check (public.dv_accounting_is_trade_admin());
drop policy if exists "transaction agents admin delete" on public.dv_accounting_transaction_agents;
create policy "transaction agents admin delete" on public.dv_accounting_transaction_agents for delete to authenticated using (public.dv_accounting_is_trade_admin());
