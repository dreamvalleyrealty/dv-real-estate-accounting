# DV Real Estate Accounting

Simple Canadian real-estate brokerage accounting and back-office application.

## Railway
Deploy this repository directly from GitHub. Build command: `npm run build`. The production app is the Vite `dist` output.

## Environment
Set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in Railway.

The application is designed to use the existing Dream Valley Supabase project while keeping new accounting data in dedicated accounting tables.

## Secure trust account information

The secure trust-account sharing workflow uses a separate encrypted table and a server-side Supabase Edge Function. It does not store full account numbers in `dv_accounting_bank_accounts`.

### Supabase migration

Apply `supabase/migrations/20261103180000_secure_trust_account_information.sql` in the Supabase SQL Editor after the existing accounting migrations. This creates the encrypted instructions store and a separate sharing audit log. The instructions table has no direct authenticated or anonymous grants. Only the Edge Function's service role can read it.

### Edge Function and environment

Deploy `supabase/functions/trust-account-information` to the same Supabase project used by this app.

Set these Edge Function secrets:

- `TRUST_ACCOUNT_ENCRYPTION_KEY`: a unique, randomly generated high-entropy secret. Keep it outside the repository and do not reuse a Supabase key.
- `TRUST_ACCOUNT_PUBLIC_URL`: the public Back Office origin, for example `https://bo.dvrealty.ca`. Do not include a path.
- `ZOHO_CLIENT_ID` and `ZOHO_CLIENT_SECRET`: the same Zoho OAuth app credentials used by `zoho-mail-send`.

The function also reads the existing Zoho refresh token from `dv_accounting_private_integrations` (`zoho_mail`) and the configured sender email. No banking detail is attached to the message.

### Recipient flow

The recipient follows a 24-hour link, requests a six-digit code sent to that same email address, then verifies and views the banking details. The code expires after 15 minutes, resend requests are throttled, and five failed attempts are allowed. The service records sender, recipient, account type(s), send status, verification and first-view time.

### Operations

Configure both trust-account records in Banking & Reconciliation > Trust Account Information as an administrator. Existing full account numbers are not imported automatically from the bank ledger; enter them in the secure setup form. When editing existing instructions, leaving the masked/blank account-number field empty preserves the encrypted account number.

The send endpoint checks the authenticated user and role independently of the browser UI. Only `SUPERADMIN` and `ADMIN` can manage both account records and send either or both types. An agent is identified through the Back Office's linked agent-user record (matching user ID and email) and can send only `REAL_ESTATE_TRUST`. Staff, manager, accountant, and viewer roles cannot send these instructions.

Before production use, verify the deployed Edge Function secrets, apply the SQL migration, and test with one administrator account, one agent account, and a recipient mailbox. Confirm that an agent request for `COMMISSION_TRUST` is rejected by the Edge Function and that no authenticated client can select from the encrypted instructions table.
