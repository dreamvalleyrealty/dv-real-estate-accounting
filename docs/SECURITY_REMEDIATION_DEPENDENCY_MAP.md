# Security Remediation Dependency Map

Branch: `accounting-upgrade-dev`
Review type: source and migration inspection only
Status: no application or database behavior changed by this review

## Scope reviewed

The current branch was inspected for the main application, transaction workspace, permission bootstrap, core accounting migrations, and selected later trust and expense workflow migrations. This map is a working dependency inventory, not a complete certification of every component or database object.

Reviewed source areas include:

- `src/App.jsx` — authentication, permission loading, navigation, banking, expenses, payroll, HST, reports, settings
- `src/Transactions.jsx` — transaction finalization, commission approval, trust receipts and transaction lifecycle
- `src/AccountingPeriods.jsx` — accounting-period UI
- `src/CommissionTrustTransfer.jsx` — commission trust transfers
- `src/SellerSettlements.jsx` — seller settlements and trust disbursements
- `src/AgentTradePortal.jsx` and `src/Listings.jsx` — agent and listing workflows
- `supabase/migrations/0030_granular_permissions.sql` — role templates and user overrides
- Core trust, expense, transaction-finalization and later seller-settlement migrations
- Later commission payout, operating-bank payment and inventory-permission migrations

## Permission flow in the frontend

1. After authentication, the app calls `dv_accounting_get_my_permissions()`.
2. The RPC returns a permission map. The app uses the `allowed` value to show or hide navigation items.
3. The frontend derives its displayed role from the loaded profile role, then JWT app metadata, then JWT user metadata.
4. The navigation helper grants all permissions in demo mode and grants all permissions when the derived role is `SUPERADMIN`.
5. The helper checks `allowed`; it does not apply the returned `access_scope` in this navigation decision. Scope must therefore be enforced by data access and server-side authorization, not assumed from the menu.

The UI permission map is a usability control. It is not a security boundary. Database RLS and server-side RPC authorization must independently enforce the same action permissions.

## Financial RPCs and workflows mapped

| Workflow | Frontend entry points / RPCs | Required server-side controls |
|---|---|---|
| Transaction finalization | `Transactions.jsx`; `dv_accounting_finalize_transaction` | Active authenticated user; transaction/company access; `transactions.finalize`; valid company; open period; atomic/idempotent posting; duplicate source journal prevention |
| Commission approval | `dv_accounting_approve_transaction_commission` | Authenticated user; transaction access; explicit commission approval permission; valid workflow state; audit actor |
| Trust deposits and disbursements | `dv_accounting_post_trust_transaction`; seller settlement payment workflow | `banking`/trust action authorization; company and bank-account ownership; correct trust type; exact client/matter/transaction/account balance; duplicate protection; posted-ledger and bank/GL atomicity |
| Seller commission transfer | `dv_accounting_process_seller_commission_transfer` | Authorized settlement/commission action; company and settlement access; correct source and destination trust accounts; sufficient funds; atomic trust and GL entries; idempotency |
| Commission cheque issuance | `dv_accounting_issue_commission_cheque`; commission-to-trust posting workflow | `commission.issue`; valid approved commission; fee/HST calculations; trust funds; no duplicate cheque or payment; audit trail |
| Vendor expense posting | `dv_accounting_post_expense` | Expense create/edit and approval rules; company access; tax evidence and eligibility; valid account mapping; open period; no duplicate journal |
| Vendor invoice payment | `dv_accounting_pay_expense_v2` | `expenses.pay`; approved and posted invoice; company-owned active operating account; partial-payment cap; idempotency; bank register and GL atomicity |
| Staff payroll posting | `dv_accounting_post_payroll` | `payroll.post`; approved run; period controls; correct payroll liabilities and remittances; idempotency |
| Manual journals | `dv_accounting_create_manual_journal` | Explicit high-privilege permission; balanced lines; company account ownership; open period; immutable posted entry; audit record |
| Role and permission administration | `dv_accounting_set_role_permission`, `dv_accounting_set_user_permission`, `dv_accounting_clear_user_permission`, role/profile RPCs | Restrict to authorized administrators; prevent self-escalation; validate permission codes and scopes; record before/after audit |

## Confirmed design and security concerns

### 1. Broad table policies can override narrow policies

PostgreSQL permissive RLS policies are combined with OR. A broad authenticated policy can therefore make a narrower permission-aware policy ineffective. The production audit found 51 unconditional permissive policies on sensitive operational and accounting tables. These require a table-by-table policy inventory and replacement plan, not a blanket policy template.

### 2. High-impact SECURITY DEFINER functions need explicit authorization

The trust posting and transaction-finalization definitions inspected in the migration history do not perform explicit caller permission checks in the function body. A SECURITY DEFINER function executes with its owner's privileges, so grants alone are not a substitute for authorization inside the function. The production audit also found 77 SECURITY DEFINER functions executable by `anon`; each grant must be reviewed against actual callers before revocation.

### 3. Trust posting needs stronger account-level controls

The inspected trust posting function checks positive amount, direction and account type, then checks available liability by company, trust type, client and matter. Its liability calculation is not scoped to the selected bank account, and the inspected definition does not verify that the bank account belongs to the supplied company. It inserts trust register, liability and bank activity rows but does not itself create the matching GL journal. The newer seller-payment workflow adds transaction/account-specific checks and GL entries, but it must be reviewed together with every caller and later function replacement.

### 4. Expense posting and payment are different authorization events

The inspected base expense-posting function creates a journal and marks the expense posted, but its definition does not require an approved invoice. A later payment RPC does require a posted and approved invoice and supports partial payments with bank or personal funding sources. The security model must distinguish creating/editing an invoice, approving it, posting it, and paying it. HST input tax credit eligibility must be independently validated; a recorded HST amount alone is not proof of an eligible ITC.

### 5. Finalization must be idempotent across all posting routes

The inspected transaction finalization function locks the transaction and returns when its status is already `FINALIZED`. Historical review nevertheless found duplicate transaction-source journal entries. The remediation must prevent duplicate postings across alternate/manual paths and historical re-finalization, not rely only on the status check in one RPC.

### 6. Permission scopes need server-side enforcement

The permission system stores `ALL`, `BRANCH` and `OWN` scopes. The frontend navigation helper only checks `allowed`. Every sensitive read and write must enforce the scope in RLS or a trusted server-side function, including company and branch boundaries. User-editable JWT metadata must never grant privileged access.

### 7. Function search paths and grants need a systematic pass

Several inspected functions are SECURITY DEFINER and use a mutable `search_path` setting of `public`. The production advisor also reported mutable search paths. Harden each function with a fixed safe search path and schema-qualified object references. Revoke public/anonymous execution only after checking triggers, scheduled jobs, internal RPC callers and frontend callers.

## Safe remediation order

1. Build a complete inventory of production RLS policies, function definitions, grants, triggers and scheduled callers.
2. Map every table read/write in the frontend to the permission code, access scope, company boundary and required role.
3. For each SECURITY DEFINER function, document the caller, required permission, ownership checks, state checks, idempotency key, audit event and execution grants.
4. Add automated tests for allowed and denied users, including cross-company, cross-branch, own-record, anonymous and inactive-profile cases.
5. Implement narrow function authorization and grant changes on a disposable test database built from a reviewed migration sequence.
6. Replace broad RLS policies table by table, testing each screen and workflow after each group.
7. Reconcile accounting totals and historical records before any production release.

## Explicit non-changes

- No production database schema, RLS policy, function, grant, permission or financial record was changed.
- No training database schema, RLS policy, function, grant, permission or financial record was changed.
- No historical accounting entries were edited, deleted, reversed or recreated.
- No migration was applied.
- This document does not claim RECO, TRESA or CRA compliance.
