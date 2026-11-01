# Financial RPC Authorization Review

Branch reviewed: `accounting-upgrade-dev`

Status: read-only source review. No application or database changes were made.

## Scope

This review traces the principal transaction, trust, seller-settlement, commission-payroll, expense and payroll actions from the React application to their database RPC calls. It is a dependency and authorization review, not a certification of RECO, CRA or accounting compliance.

## Action-to-RPC map

| Workflow | Frontend caller | Database action | Authorization concern to resolve |
|---|---|---|---|
| Approve transaction commission | `src/Transactions.jsx`, `approveAmount` | `dv_accounting_approve_transaction_commission` | The action is reachable through the transaction workflow; enforce a dedicated approval permission, active profile, company/branch scope and separation of duties in the database. |
| Finalize transaction | Transaction editor workflow | `dv_accounting_finalize_transaction` | General transaction edit access is not sufficient. Require `transactions.finalize` and validate company/branch ownership server-side. |
| Close trade / send to payroll | `src/Transactions.jsx` | `dv_accounting_close_transaction`, `dv_accounting_resend_commission_to_payroll` | Verify who may close, reopen or resend, and make each operation idempotent. |
| Issue commission cheque/EFT | `src/App.jsx`, `CommissionPaymentDialog` | `dv_accounting_issue_commission_cheque` | The payroll dialog calls the RPC without receiving the granular permission map. Enforce `commission.issue` inside the RPC. |
| Post seller/landlord payment | `src/SellerSettlements.jsx` | `dv_accounting_post_listing_seller_payment` | Enforce a dedicated seller-payment permission and active company-owned Real Estate Trust account, exact matter/client allocation and available balance. |
| Transfer seller commission | `src/CommissionTrustTransfer.jsx` | `dv_accounting_process_seller_commission_transfer` | Enforce a dedicated transfer permission, settlement state, source/destination trust-account validation and idempotency. |
| Pay outside brokerage | `src/Transactions.jsx` | `dv_accounting_post_trust_transaction` | This core trust-posting RPC has broad legacy authorization exposure. Require a dedicated disbursement permission and exact trust-liability/account matching. |
| Post operating expense | `src/App.jsx` | `dv_accounting_post_expense` | Require approved invoice state, expense-post permission, company scope and idempotent journal creation. |
| Pay operating expense | `src/App.jsx` | `dv_accounting_pay_expense_v2` | Require expense-pay permission, validated funding source and bank account, and prevent duplicate payment posting. |
| Approve payroll run | `src/App.jsx` | Direct update to payroll run status | This is not an RPC boundary. Confirm RLS and require a dedicated payroll approval permission and separation of duties. |
| Post payroll | `src/App.jsx` | `dv_accounting_post_payroll` | Review function-level permission checks, period controls, duplicate posting and approval separation. |
| Manual journal | `src/App.jsx` | `dv_accounting_create_manual_journal` | UI currently limits this to Super Admin; retain server-side role/permission, open-period, balanced-entry and audit checks. |

## Confirmed application-layer inconsistencies

1. The transaction editor's local `isSuperAdmin` state is populated using role values that include `user_metadata`. Supabase user metadata is user-editable and must not grant privileges.
2. The Agents/Fees component similarly builds role decisions from several sources, including `user_metadata`.
3. The Seller Settlements page receives a role string rather than the granular permission map. Its reopen flow independently reads profile and JWT role values.
4. The Commission Payroll payment dialog invokes `dv_accounting_issue_commission_cheque` directly and is not passed the granular permission map.
5. The Transactions page's read-only state is based on general edit/manage permissions. This is suitable for editing visibility only; it must not authorize approval, finalization or disbursement.
6. Some workflows perform a financial RPC and then a separate client-side update. For example, issuing a commission cheque is followed by a separate update of payment method/reference and the transaction payroll status. Failure between steps can leave the UI and accounting records out of sync. The database operation should own all financially material state transitions atomically.

## Permission resolver requirements

Use one server-side resolver for financial RPCs and RLS policies. Its behavior should be consistent:

1. Require an authenticated `auth.uid()`.
2. Require an active user profile associated with the correct brokerage/company.
3. Use a trusted role source. Never use `user_metadata` for authorization.
4. Apply Super Admin privileges only after verifying the active profile and brokerage context.
5. If a user-specific override exists, it takes precedence over the role rule, including an explicit deny.
6. Otherwise use the role-permission rule; default to deny.
7. Enforce `ALL`, `BRANCH` and `OWN` scopes against the actual target row, not merely the screen or request payload.
8. Record the actor, permission, target, timestamp and reason/reference for sensitive state changes.
9. Enforce separation of duties where appropriate, especially approval, trust disbursement, commission payment and period close.
10. Make posting operations idempotent and atomic. A retry must not create another cheque, trust movement, bank transaction or journal entry.

## RLS and ACL remediation constraints

- PostgreSQL permissive RLS policies combine with OR logic. A narrow policy does not restrict access if a broad permissive policy still grants the same operation.
- Remove or narrow broad policies only after mapping all legitimate frontend and backend dependencies.
- Revoke anonymous/PUBLIC execution from financial SECURITY DEFINER functions after checking every caller, trigger and service-role dependency.
- Trigger functions should be callable through their trigger only where possible; do not break legitimate trigger execution while tightening direct RPC access.
- SECURITY DEFINER functions need a fixed safe `search_path`, schema-qualified object references and explicit authorization inside the function.
- Do not add broad policies to tables that currently have no policies. Some are intentionally fail-closed worker or integration tables.

## Recommended implementation sequence

### Phase A — shared authorization foundation
- Define a single permission-check helper with explicit-deny precedence and scope enforcement.
- Resolve trusted role/profile precedence and inactive-user behavior.
- Add tests for no session, inactive profile, stale JWT role, explicit deny, branch scope, own scope and cross-company access.

### Phase B — financial RPCs
- Secure transaction approval/finalization/close.
- Secure trust posting, seller payment and seller commission transfer.
- Secure commission cheque issue, correction, deletion and send-back operations.
- Secure expense post/pay, payroll approve/post and manual journals.
- Make each financial operation atomic and idempotent.

### Phase C — RLS and function ACLs
- Inventory every policy on the affected tables, including policy command, permissive/restrictive mode and expression.
- Resolve broad-policy OR conflicts.
- Revoke anon/PUBLIC execution from financial functions after dependency checks.
- Fix mutable search paths and audit SECURITY DEFINER ownership/privileges.

### Phase D — validation
- Use a disposable training database with a migration baseline reconciled to the repository.
- Test each role and scope, including explicit user denies.
- Test duplicate submissions, retries, partial failures, concurrent requests, wrong brokerage, wrong branch, inactive bank account, insufficient trust liability and closed accounting periods.
- Compare opening and closing trial balances, bank registers, trust client ledgers, liabilities and journals before and after every test.
- Do not deploy to production until the migration and rollback plan have been reviewed and approved.

## Important limitations

The training Supabase project is not currently a reliable mirror of production or the current repository migration history. Do not run the full migration directory against it blindly. Build a clean disposable test baseline or reconcile migration history first.

This document records source-level findings. Production catalog observations are documented separately in `docs/SECURITY_REVIEW.md`; live production has not been modified.
