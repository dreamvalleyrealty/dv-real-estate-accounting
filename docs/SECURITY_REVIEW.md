# Dream Valley Accounting — Security Review

Date: 2026-10-31
Repository: `dreamvalleyrealty/dv-real-estate-accounting`
Working branch: `accounting-upgrade-dev`
Production project: `DV-Back-Office` (`bjriisauroukyuhbfkuh`)
Training project: `DV Real Estate Accounting Training` (`mqnbifhhdhauuaqkvhbk`)

## Scope and safety

This is a read-only review of database metadata, selected function definitions, RLS policies and frontend dependencies. No production or training database permissions, policies, functions, tables, migrations or accounting records were changed.

The GitHub Actions workflow completed successfully for commit `eb02f8105e46c68a9ff9a55405ffe3f63fb68824`. A later documentation-only commit is still running through the same workflow.

## Findings

### 1. Production RLS policies are too broad

The production database has 51 permissive policies whose conditions are unconditionally true for row visibility and/or writes. The affected set includes sensitive accounting and operational tables such as bank accounts and transactions, trust transactions and liabilities, journal entries, expenses and payments, commissions and cheques, payroll, agent bank details, and transaction records.

Because PostgreSQL combines permissive policies with OR, a broad unconditional policy can make a narrower policy ineffective. Authentication alone therefore does not enforce the role distinctions configured by the application.

**Risk:** A signed-in user may be able to read or change records beyond their intended application role. This is a database access-control issue, not merely a front-end visibility issue.

### 2. Production SECURITY DEFINER functions are executable by anon

The production database has 77 SECURITY DEFINER functions executable by the `anon` role. The Supabase security advisor has also reported a large set of SECURITY DEFINER functions callable by authenticated users. Some functions are internal helpers or trigger functions, so each one must be reviewed before changing grants. Do not blanket-revoke every function.

Selected production function definitions were checked directly:

- `dv_accounting_post_trust_transaction`: SECURITY DEFINER; no explicit `auth.uid()` or role check in the body. The reviewed implementation does not verify that the selected bank account is active and belongs to the supplied company, and it does not scope the available-liability calculation to the selected bank account. It creates trust-register, liability and bank-register rows but no corresponding GL journal.
- `dv_accounting_finalize_transaction`: SECURITY DEFINER; no explicit `auth.uid()` or role check in the body. It creates journal and trust records. Its row lock and FINALIZED status check help protect this one route from repeat finalization, but do not prevent duplicate posting through other event paths.
- `dv_accounting_approve_transaction_commission`: SECURITY DEFINER; no explicit `auth.uid()` or role check in the body.
- `dv_accounting_post_expense`: SECURITY DEFINER; no explicit `auth.uid()` or role check in the body, and the reviewed implementation does not require approval before posting.
- `dv_accounting_run_recurring_fees`: SECURITY DEFINER; no explicit `auth.uid()` or role check in the body.
- `dv_accounting_pay_expense_v2`: SECURITY DEFINER; the reviewed definition does check for an authenticated user and an approved expense. It still needs a complete permission and role review.

These findings are specific to the definitions inspected; the remaining SECURITY DEFINER functions need a full inventory of callers, trigger dependencies, authorization and search-path settings before remediation.

### 3. Function search paths need hardening

The security advisor flags functions with mutable search-path settings. A SECURITY DEFINER function should use a fixed safe path and schema-qualify referenced objects. A path set only to `public` is not the same as a hardened `pg_catalog, public` path.

### 4. Six production tables have RLS enabled but no policies

The production database currently has six RLS-enabled tables without policies:

- `dv_accounting_agent_charge_payments`
- `dv_accounting_agent_service_catalog`
- `dv_accounting_private_integrations`
- `dv_accounting_scheduled_email_worker_auth`
- `dv_accounting_transaction_deposits`
- `dv_accounting_transaction_file_requirements`

This may intentionally block direct API access. Review each workflow before adding policies. Do not open private integrations or worker-authentication data to ordinary application users.

### 5. The training database is not an adequate mirror of production

Production reports 219 migration-history entries and contains the granular permission catalog, role rules, user overrides and `dv_accounting_get_my_permissions()` RPC expected by the current frontend.

The training database reports 75 migration-history entries, lacks that RPC and granular permission tables, and instead contains an older coarse role-permission structure. It also has its own broad policies and function grants. Do not use it as proof that a security migration will work against the current production schema.

See `docs/TRAINING_ENVIRONMENT_DRIFT.md` for the comparison and the safe alignment plan.

## Required implementation order

1. Build a role/action matrix from the live permission catalog, per-user overrides, frontend checks, direct table operations, RPC calls, triggers and storage access.
2. Classify every SECURITY DEFINER function as frontend RPC, internal helper, trigger function or service-only operation. Record exact callers and authorization requirements.
3. Remove anonymous execution from privileged RPCs only after confirming dependencies. Add internal authentication and role/permission checks to state-changing functions.
4. Replace unconditional table policies in controlled groups. Define read, insert, update and delete separately; preserve agent self-service and staff workflows; scope records to the correct company, branch and agent where the schema supports it.
5. Add database tests for anonymous denial, role-specific access, cross-company isolation, agent ownership, and unauthorized financial posting.
6. Align the training environment with the current migration set or create a clean test environment from that exact set. Run application and database tests before preparing any production release.

## Do not do

- Do not replace all policies with one generic role check.
- Do not grant broad access to tax, bank-detail, private integration or worker-authentication tables to make the UI work.
- Do not revoke authenticated execution from every function without checking frontend and trigger dependencies.
- Do not change production permissions, policies, functions or accounting records as part of this development work.
- Do not edit or delete historical accounting records to make test results appear balanced.

## Current status

The read-only security review is complete. No security remediation has been applied. The next implementation step is to finish the role/action and function-dependency maps against production metadata, then build a test environment that matches the current repository before preparing small, testable security migrations.
