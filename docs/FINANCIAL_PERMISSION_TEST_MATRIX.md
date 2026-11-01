# Financial Permission Test Matrix

**Branch:** `accounting-upgrade-dev`  
**Status:** Source-derived test specification; not an authorization certification  
**Source of role-template defaults:** `supabase/migrations/0030_granular_permissions.sql`

This matrix describes the role-template logic in migration 0030. It is a test baseline, not a recommendation to preserve every current grant. In particular, the ADMIN expression in the migration evaluates to true for every catalog permission.

## 1. Role-template baseline

| Role | Expected default from migration 0030 | Scope seeded by migration |
|---|---|---|
| SUPERADMIN | Allow all 43 catalog permissions | ALL |
| ADMIN | Allow all 43 catalog permissions; expression `c.code not in (...) or true` is always true | ALL |
| MANAGER | Allow only the explicit list below | ALL |
| ACCOUNTANT | Allow permissions in the listed finance modules, except the explicit denied codes below | ALL |
| STAFF | dashboard.view, agents.view, staff.view, staff.hours.manage, reports.view | OWN |
| VIEWER | dashboard.view, reports.view; all other catalog permissions denied by fallback | ALL |

**Migration behavior to account for:** role defaults are inserted with `ON CONFLICT DO NOTHING`. Existing role-rule rows are therefore not refreshed by rerunning this migration. Tests must inspect the actual database rows, not assume the seed CASE expression is the live value.

### MANAGER allow-list

`dashboard.view`, `transactions.view`, `transactions.create`, `transactions.edit`, `banking.view`, `expenses.view`, `expenses.create`, `expenses.edit`, `agents.view`, `agents.create`, `agents.edit`, `agents.import`, `agents.documents.view`, `agents.documents.manage`, `fees.view`, `fees.manage`, `commission.view`, `commission.preview`, `commission.issue`, `staff.view`, `staff.create`, `staff.edit`, `staff.hours.manage`, `staff.documents.view`, `reports.view`, `reports.export`, `compliance.view`, `settings.view`.

All other catalog permissions should be denied by the MANAGER role template unless a user override exists.

### ACCOUNTANT rule

The migration allows permissions whose module is one of: Dashboard, Transactions, Banking, Expenses & A/P, Commission Payroll, Staff Payroll, HST / Tax, Reports, Compliance.

It then denies these codes even when their module is included:

- `transactions.create`, `transactions.edit`, `transactions.finalize`
- `banking.reconcile`
- `expenses.create`, `expenses.edit`, `expenses.pay`
- `commission.issue`
- `staff.create`, `staff.edit`, `staff.hours.manage`
- `payroll.approve`, `payroll.post`
- `tax.manage`, `compliance.close`

All other permissions in those modules are allowed by the template. Permissions in modules outside that list are denied.

## 2. Full permission catalog coverage

Every catalog code must have a test for each role, using the role rules above and then applying the user-override precedence in section 3.

| Module | Permission codes |
|---|---|
| Dashboard | `dashboard.view` |
| Transactions | `transactions.view`, `transactions.create`, `transactions.edit`, `transactions.finalize` |
| Banking | `banking.view`, `banking.reconcile` |
| Expenses & A/P | `expenses.view`, `expenses.create`, `expenses.edit`, `expenses.pay` |
| Agents | `agents.view`, `agents.create`, `agents.edit`, `agents.import`, `agents.delete`, `agents.documents.view`, `agents.documents.manage` |
| Agent Fees | `fees.view`, `fees.manage` |
| Commission Payroll | `commission.view`, `commission.preview`, `commission.issue` |
| Staff Payroll | `staff.view`, `staff.create`, `staff.edit`, `staff.hours.manage`, `staff.documents.view`, `staff.documents.manage`, `payroll.view`, `payroll.calculate`, `payroll.approve`, `payroll.post`, `payroll.remit` |
| HST / Tax | `tax.view`, `tax.manage` |
| Reports | `reports.view`, `reports.export` |
| Compliance | `compliance.view`, `compliance.close` |
| Settings | `settings.view`, `settings.company.manage`, `settings.banking.manage`, `settings.users.manage`, `settings.roles.manage` |

## 3. User override precedence tests

The resolver in migration 0030 uses `coalesce(user_override.allowed, role_rule.allowed, false)`. Verify all of these for every permission family, and specifically for high-risk financial actions:

| Role default | User override | Expected effective result |
|---|---|---|
| Allow | Explicit deny | Deny |
| Deny | Explicit allow | Allow, subject to scope and other server-side safeguards |
| Allow | No override | Allow |
| Deny | No override | Deny |
| Missing role rule | No override | Deny |
| Any | Override row for a different user | No effect on current user |
| Any | Inactive or missing user profile | Permission resolver returns no permissions / deny |
| Any | Unauthenticated caller | RPC denied |

Test explicit deny for at least `transactions.finalize`, `banking.reconcile`, `expenses.pay`, `commission.issue`, `payroll.approve`, `payroll.post`, `tax.manage`, `compliance.close`, and both settings-management permissions.

## 4. Access-scope test matrix

The current catalog resolver returns a scope value, but a returned scope is not proof that database queries or write RPCs enforce it. Test each permission against records in the user's own scope, another branch, and another user's ownership.

| Effective scope | Own record | Same-branch record owned by someone else | Different-branch record |
|---|---:|---:|---:|
| ALL | Allow | Allow | Allow |
| BRANCH | Allow if in assigned branch | Allow if in assigned branch | Deny |
| OWN | Allow | Deny | Deny |

For each scope, test both SELECT and write paths. For a financial action, verify the target record's company and branch are resolved server-side; do not trust a branch ID supplied by the browser. If a record has no owner or branch, the expected behavior must be explicitly defined and tested rather than silently treating it as ALL.

## 5. High-risk financial action cases

| Action / permission | Positive case | Negative case | Additional control |
|---|---|---|---|
| Finalize transaction — `transactions.finalize` | Authorized user finalizes a draft in permitted scope | Explicit deny, wrong branch, inactive user, or already-finalized record | Atomic posting; idempotency; balanced journal; immutable posted state and reversal path |
| Reconcile bank — `banking.reconcile` | Authorized user reconciles the selected bank account and period | Deny user, wrong branch/company, closed period | Account-specific reconciliation; independent reviewer; no fabricated sign-off |
| Pay expense — `expenses.pay` | Authorized user pays an approved, posted expense | Unapproved/unposted expense, explicit deny, wrong bank account scope | Payment and bank/GL effects atomic; partial payment and duplicate prevention |
| Issue commission — `commission.issue` | Authorized user issues an eligible commission cheque | Explicit deny, duplicate issue, invalid agent/transaction scope | Validate approved commission, deductions, HST evidence and idempotency |
| Approve payroll — `payroll.approve` | Authorized approver approves a calculated run | Preparer attempts own approval where separation is required; explicit deny | Approval recorded server-side with actor and timestamp |
| Post payroll — `payroll.post` | Authorized user posts an approved run | Unapproved run, explicit deny, closed period | Atomic journal and payroll status update; duplicate-post prevention |
| Manage HST — `tax.manage` | Authorized user edits an open working paper | Explicit deny, closed/filed period, out-of-scope company | Preserve source documents, tax-code decisions and change history |
| Close month end — `compliance.close` | Authorized reviewer closes a period with all required controls complete | Missing reconciliation, unresolved exceptions, explicit deny | Authenticated reviewer; immutable close snapshot and reopen audit trail |
| Manage bank setup — `settings.banking.manage` | Authorized admin changes bank configuration | Explicit deny or wrong brokerage | Dual control for trust-account changes; audit before/after values |

## 6. Permission administration tests

- Only an authorized, active SUPERADMIN/ADMIN may change role templates or another user's overrides.
- An explicit user deny must override an allowed role rule in every enforcement layer, including RLS policies and SECURITY DEFINER RPCs.
- A user must not change their own override through the administrative RPC.
- Reject invalid role names, permission codes, scopes, null actor identity and inactive actors.
- Test whether ADMIN may edit SUPERADMIN role rules or grant itself additional powers; define the intended boundary before implementation.
- Role changes must invalidate or refresh stale JWT/app state. The profile role and trusted `app_metadata` role must not disagree silently.
- Preserve who changed a permission, what changed, when, and the reason/ticket reference.

## 7. Cross-layer consistency tests

For every permission above, assert the same outcome at all applicable layers:

1. Permission resolver result.
2. Frontend control visibility (usability only).
3. Direct table SELECT/INSERT/UPDATE/DELETE under RLS.
4. Direct RPC invocation, bypassing the UI.
5. Related SECURITY DEFINER function and nested function calls.
6. Cross-company, cross-branch and cross-owner attempts.
7. Audit event and financial side effects.

**Known source-level exception requiring remediation:** the inventory write-policy migration checks for any allowed user override or role rule using separate `EXISTS` predicates. That pattern can allow a role grant to defeat an explicit user deny. It also reads `user_metadata` and does not enforce ALL/BRANCH/OWN scope. Do not treat the permission resolver test as proof that those policies pass.

## 8. Execution order and release gates

1. Extract the live catalog, role-rule rows, user overrides, profile active state, company membership and branch assignments from the disposable training environment. Do not infer live values from migration seed logic.
2. Convert sections 1–7 into automated SQL/RPC integration tests using dedicated test identities for each role and scope.
3. Run tests against a disposable database with representative financial records and no production data.
4. Fix the shared server-side authorization resolver and then migrate each RLS policy/RPC to it in dependency order.
5. Re-run the full matrix, including direct RPC and cross-scope negative tests.
6. Reconcile financial balances and verify no existing user workflow has been unintentionally removed before considering deployment.

No production database changes are authorized by this document. Do not run migrations against production as part of test setup.
