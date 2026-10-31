# Dream Valley Accounting Upgrade — Baseline

Date: 2026-10-31
Repository: `dreamvalleyrealty/dv-real-estate-accounting`
Working branch: `accounting-upgrade-dev`
Test database: `DV Real Estate Accounting Training` (`mqnbifhhdhauuaqkvhbk`)

## Scope and safeguards

This branch is the development workspace. The training Supabase project is the only database to be used for upgrade testing. The production project must not receive schema, data, permission, or function changes until the changes have been reviewed, tested, and separately approved.

The training database has no accounting transactions, bank accounts, expenses, trust ledgers, journal entries, or reconciliations. It does contain 35 real-estate-board reference rows and six role-permission rows. Its migration history is populated. Treat it as a schema/integration test environment, not as a production-data copy.

## Verified baseline risks

### Trust posting

- `dv_accounting_post_trust_transaction` is SECURITY DEFINER and currently executable by both `anon` and `authenticated`.
- The function validates that the bank account's type matches the requested trust type, but the retrieved function body does not verify that the bank account belongs to the supplied company and is active.
- The disbursement availability calculation groups by company, trust type, client and matter, but does not scope the liability calculation to the selected bank account.
- The function inserts a trust transaction, liability row and bank transaction. It does not create a corresponding general-ledger journal entry.
- There is no database-enforced idempotency key for an ordinary trust deposit or disbursement.

### Transaction finalization and journal posting

- `dv_accounting_finalize_transaction` uses a row lock and returns early when the transaction is already FINALIZED. That is useful protection, but it does not provide a durable unique posting-event key if another workflow resets status or creates the same posting through a different path.
- The function creates commission receivable, revenue, HST payable, agent commission expense and agent payable lines. It also creates trust subledger and bank-register rows for a transaction deposit.
- The current journal entry schema does not have a dedicated posting-event/idempotency key.
- Before adding a unique constraint, map every legitimate journal event for a transaction (finalization, receipt, commission payment, correction and reversal). A transaction may legitimately have more than one journal event.

### Row-level security and RPC exposure

- The training schema has broad `authenticated access` ALL policies with unconditional `USING (true)` and `WITH CHECK (true)` on journal entries, journal lines, trust transactions, trust liabilities and bank transactions.
- The trust-posting and transaction-finalization SECURITY DEFINER RPCs are executable by `anon` as well as `authenticated`.
- The current role resolver uses the active `dv_accounting_user_profiles` row first and falls back to `auth.users.raw_app_meta_data.role`. Authorization changes should rely on trusted profile/app metadata, never editable user metadata.
- The audit-log read policy references both app metadata and user metadata. Remove the user-metadata fallback from authorization.
- The latest training security advisor scan also flags two SECURITY DEFINER views, three functions with mutable search paths, and two RLS-enabled tax-slip tables without policies.

### Existing application test coverage

- `package.json` has a Vite build script but no test, lint, or type-check script.
- Add database-level tests for permissions, idempotency, trust-account isolation, balanced journals, reversals, and period locks before changing posting functions.

## Implementation sequence

1. **Map and freeze the posting contract.** Trace each source event to all journal, bank, trust-liability and commission/payroll records. Identify legitimate multi-event transactions and existing duplicate paths.
2. **Harden access.** Replace broad policies with role- and company-scoped policies that preserve required staff/agent workflows. Revoke anonymous execution from sensitive RPCs, then grant only to the intended signed-in roles. Verify every SECURITY DEFINER function has a fixed safe search path and an internal authorization check.
3. **Make posting idempotent.** Introduce explicit posting-event identifiers and database uniqueness for each event type. Use transaction locks and atomic writes. Do not impose a single-journal-per-transaction rule.
4. **Correct trust controls.** Validate active bank account, company ownership and account type; calculate available liability for the exact bank account/client/matter; prevent duplicate event submissions; and require a reversal rather than editing posted trust history.
5. **Integrate trust with the GL.** Define bank-to-GL and trust-liability account mappings before posting journals. Keep Real Estate Trust, Commission Trust and Operating separate. Add three-way reconciliation controls.
6. **Add automated tests and reports.** Test concurrent/repeated posting, cross-company access, unauthorized roles, deposit/disbursement boundaries, balanced journals, reversals and closed periods. Add reconciliation and audit reports.
7. **Validate and release.** Run migrations only in training, compare expected ledgers and reports, obtain review, then prepare a separate production deployment plan and approval.

## Explicit non-goals for this baseline commit

- No production database changes.
- No historical transaction or journal-entry edits.
- No blanket RLS policy replacement.
- No automatic journal repair or deletion.
- No claim of RECO or CRA compliance until the relevant controls and reports are independently verified.
