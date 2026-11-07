# DV Real Estate Accounting

Simple Canadian real-estate brokerage accounting and back-office application.

## Railway
Deploy this repository directly from GitHub. Build command: `npm run build`. The production app is the Vite `dist` output.

## Environment
Set `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_GOOGLE_MAPS_API_KEY` in Railway. The Open House Signs module uses Google Maps JavaScript API, Places API, and Geocoding API; enable billing and restrict the browser key to the Back Office domain. The Directions service is used to preview the sign route and Google Maps opens turn-by-turn navigation.

The application is designed to use the existing Dream Valley Supabase project while keeping new accounting data in dedicated accounting tables.

## Secure trust account information

The secure trust-account sharing workflow uses a separate encrypted table and a server-side Supabase Edge Function. It does not store full account numbers in `dv_accounting_bank_accounts`.

### Supabase migration

Apply `supabase/migrations/20261103180000_secure_trust_account_information.sql` in the Supabase SQL Editor after the existing accounting migrations. This creates the encrypted instructions store and a separate sharing audit log. The instructions table has no direct authenticated or anonymous grants. Only the Edge Function's service role can read it.

### Edge Function and environment

Deploy `supabase/functions/trust-account-information` to the same Supabase project used by this app with JWT gateway verification disabled (for example, `supabase functions deploy trust-account-information --no-verify-jwt`). The function validates signed-in sender requests itself; the recipient endpoints use the random 256-bit link token and OTP.

Set these Edge Function secrets:

- `TRUST_ACCOUNT_ENCRYPTION_KEY`: a unique, randomly generated high-entropy secret of at least 32 characters. Keep it outside the repository and do not reuse a Supabase key.
- `TRUST_ACCOUNT_PUBLIC_URL`: the public Back Office origin, for example `https://bo.dvrealty.ca`. Do not include a path.
- `ZOHO_CLIENT_ID` and `ZOHO_CLIENT_SECRET`: the same Zoho OAuth app credentials used by `zoho-mail-send`.

The function also reads the existing Zoho refresh token from `dv_accounting_private_integrations` (`zoho_mail`) and the configured sender email. No banking detail is attached to the message.

### Recipient flow

The recipient follows a 24-hour link, requests a six-digit code sent to that same email address, then verifies and views the banking details. The code expires after 15 minutes, resend requests are throttled, and five failed attempts are allowed. The service records sender, recipient, account type(s), send status, verification and first-view time.

### Operations

Configure both trust-account records in Banking & Reconciliation > Trust Account Information as an administrator. Enter the bank name, three-digit Canadian institution number, five-digit transit number, full account number, account name, and any bank/wire instructions. Existing full account numbers are not imported automatically from the bank ledger; enter them in the secure setup form. When editing existing instructions, leaving the blank account-number field empty preserves the encrypted account number. Agents use Agent Portal > Trust Account Information and can share Real Estate Trust details only.

The send endpoint checks the authenticated user and role independently of the browser UI. Only `SUPERADMIN` and `ADMIN` can manage both account records and send either or both types. An agent is identified through the Back Office's linked agent-user record (matching user ID and email) and can send only `REAL_ESTATE_TRUST`. Staff, manager, accountant, and viewer roles cannot send these instructions.

Before production use, verify the deployed Edge Function secrets, apply the SQL migration, and test with one administrator account, one agent account, and a recipient mailbox. Confirm that an agent request for `COMMISSION_TRUST` is rejected by the Edge Function and that no authenticated client can select from the encrypted instructions table.

### Pre-release security checks

- Sign in as an administrator and confirm both trust account records can be configured and either or both account types can be shared.
- Sign in as a linked agent and confirm the Agent Portal shows only the Real Estate Trust sharing page.
- Invoke `send_link` as an agent with `COMMISSION_TRUST` in `accountTypes`; the function must return HTTP 403.
- Attempt a direct authenticated read of `dv_accounting_trust_account_instructions`; it must be denied.
- Open a valid recipient link, request the OTP, and confirm the code arrives at the target email address.
- Confirm an incorrect code is rejected, the code expires after 15 minutes, the link expires after 24 hours, and the same link cannot reveal instructions a second time.
- Confirm the audit history records sender, recipient, shared account type(s), send status, verification time and first-view time.

 
## Listing-specific deposit instructions

The separate **Send Deposit Instructions** workflow is exposed from the Listings workspace for both agents and administrators. Agents can select only listings assigned to their linked agent profile; administrators can select any brokerage listing. The Edge Function independently enforces this rule.

The workflow sends the supplied one-page Real Estate Trust deposit-instructions document as a PDF attachment to the buyer's agent. The email includes the selected property address. No secure link or OTP is used for this listing-specific email. The sender and recipient, selected listing, send time, and email status remain in the audit history. The PDF is generated server-side from the approved document text and attached through the Zoho Mail attachment API.


## Open House Directional Signs

The **Open House Signs** workspace is available in the agent portal and the administrator Back Office navigation. It stores open house events, shared sign-location records, per-event installation and collection status, and sign photos in the private `dv-open-house-sign-photos` Storage bucket. Agents can reuse saved sign locations within 5 km of a new property.

Configure `VITE_GOOGLE_MAPS_API_KEY` in the Railway service environment before using the map. Enable Maps JavaScript API, Places API (New), and Geocoding API in Google Cloud, enable billing, and apply HTTP-referrer and API restrictions to the key. After changing the environment variable, redeploy the app. Google Places suggestions are candidates only; agents must confirm each location is safe and permitted before placing a sign.

Database migrations:
- `supabase/migrations/20261106213000_open_house_directional_signs.sql`
- `supabase/migrations/20261106220000_open_house_sign_photo_and_shared_read.sql`
