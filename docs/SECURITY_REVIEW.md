# Dream Valley Accounting — Security Review

Date: 2026-10-31
Repository: `dreamvalleyrealty/dv-real-estate-accounting`
Working branch: `accounting-upgrade-dev`
Database inspected: `DV Real Estate Accounting Training` (`mqnbifhhdhauuaqkvhbk`)

## Scope and safety

This is a read-only review of the training database and the development branch. No database permissions, policies, functions, tables, or accounting records were changed during this review. Production was not queried for this review and remains unchanged.

The GitHub Actions workflow `Build and Version Check` ran for commit `eb02f8105e46c68a9ff9a55405ffe3f63fb68824` on the development branch and completed with conclusion `success`.

## Findings

### 1. Broad row-level security policies

The training database currently has 50 permissive policies whose conditions are unconditionally true for both row visibility and writes. These policies apply to sensitive tables, including bank accounts and transactions, trust transactions and liabilities, journal entries and lines, expenses and payments, commissions and cheques, payroll, agent bank details, user settings, and transaction records.

Because PostgreSQL combines permissive policies with OR, a broad unconditional policy can make a narrower policy ineffective. Authentication alone therefore does not enforce the role distinctions configured by the application.

**Risk:** Any signed-in user who can reach these tables may be able to read or change records beyond their intended application role. The current training role-permission rows (SUPERADMIN, ADMIN, ACCOUNTANT, MANAGER, STAFF and VIEWER) do not by themselves constrain direct table access.

### 2. SECURITY DEFINER functions exposed to anonymous requests

The security advisor reports 21 SECURITY DEFINER functions executable by `anon` and 27 executable by `authenticated`. A SECURITY DEFINER function runs with its owner's privileges, so each exposed function needs its own authorization and input validation.

Reviewed examples:

- `dv_accounting_post_trust_transaction`: no explicit authenticated-user or role check; does not verify that the selected bank account is active or belongs to the supplied company; calculates available client/matter liability across the trust account type without restricting it to the selected bank account; creates trust register, liability and bank-register rows but no GL journal.
- `dv_accounting_finalize_transaction`: no explicit authenticated-user or role check; selects the first company when the transaction has no company; posts journal and trust records. A row lock and FINALIZED status check help prevent repeat finalization through this route, but do not prevent duplicate events through other routes.
- `dv_accounting_approve_transaction_commission`: updates commission approval without checking the caller's role.
- `dv_accounting_post_expense`: does not require approval before posting; uses a generic GL bank code rather than a bank-account-specific mapping.
- `dv_accounting_run_recurring_fees`: no explicit authenticated-user or role check.
- `dv_accounting_set_user_role`: contains a SUPERADMIN-only role check; keep that guard and separately restrict anonymous execution.

The function `dv_accounting_current_user_role` resolves the active profile first and falls back to trusted `raw_app_meta_data`. That fallback is preferable to editable user metadata. The audit-log policy still needs review because it includes a user-metadata authorization fallback.

### 3. Function search paths

The security advisor also reports functions with mutable search-path settings. A SECURITY DEFINER function should use a fixed safe path and schema-qualify referenced objects. A path set only to `public` is not the same as a hardened `pg_catalog, public` path.

### 4. Tables with RLS enabled but no policies

Two training tables have RLS enabled and no policies: `dv_accounting_tax_slips` and `dv_accounting_tax_years`. This may intentionally block access, but the application workflow must be checked before adding any policy. Do not open them broadly; tax-slip data is sensitive.

## Required implementation order

1. Inventory every table, policy, view, RPC and frontend call. Map each role to the exact read/write actions it needs.
2. Remove anonymous execution from privileged RPCs. Retain authenticated execution only where the function is intended to be called by the signed-in application, and add an internal role check to every state-changing SECURITY DEFINER function.
3. Replace unconditional table policies in controlled groups. Define read, insert, update and delete separately; preserve agent self-service and staff workflows; scope records to the correct company and agent where the schema supports it.
4. Review and harden every SECURITY DEFINER function, including safe search paths, authorization checks, input validation and transaction locking.
5. Add tests that prove anonymous access is denied, each application role can perform only its permitted actions, and financial posting functions reject unauthorized and cross-company requests.
6. Run the security advisor and end-to-end application tests in the training environment after each group of changes.

## Do not do

- Do not replace all policies with one generic role check.
- Do not grant broad access to tax-slip or bank-detail tables to make the UI work.
- Do not revoke authenticated execution from every function without first checking frontend and trigger dependencies.
- Do not change production permissions or policies as part of this development work.
- Do not edit or delete historical accounting records to make test results appear balanced.

## Current status

The security review is complete as a read-only assessment. No security remediation has yet been applied. The next implementation step is a role/action matrix and a dependency map for the frontend RPCs and table access, followed by small, testable training-only migrations.
