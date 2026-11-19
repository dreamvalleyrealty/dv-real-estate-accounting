-- Add a dedicated permission for showing bank balances on the Dashboard.
insert into public.dv_accounting_permission_catalog
  (code,module,label,description,sort_order)
values
  ('dashboard.bank_balances.view','Dashboard','View bank balances on dashboard','Allows viewing account names, account types and calculated balances in the Dashboard bank balance widget without granting access to the Banking & Reconciliation module.',11)
on conflict (code) do update set
  module=excluded.module,
  label=excluded.label,
  description=excluded.description,
  sort_order=excluded.sort_order;

-- Remove legacy permissive policies that granted every authenticated user
-- unrestricted access and therefore bypassed the permission-based policies.
drop policy if exists "authenticated access" on public.dv_accounting_bank_accounts;
drop policy if exists "authenticated access" on public.dv_accounting_bank_transactions;

-- A user may read bank data for the Banking module OR for the Dashboard widget.
drop policy if exists "dv_permission_select" on public.dv_accounting_bank_accounts;
create policy "dv_permission_select"
on public.dv_accounting_bank_accounts
for select
to authenticated
using (
  public.dv_accounting_has_permission_all_scope('banking.view')
  or public.dv_accounting_has_permission_all_scope('dashboard.bank_balances.view')
);

drop policy if exists "dv_permission_select" on public.dv_accounting_bank_transactions;
create policy "dv_permission_select"
on public.dv_accounting_bank_transactions
for select
to authenticated
using (
  public.dv_accounting_has_permission_all_scope('banking.view')
  or public.dv_accounting_has_permission_all_scope('dashboard.bank_balances.view')
);
