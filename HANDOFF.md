# Dream Valley Real Estate Accounting — Handoff

## Project

- **Repository:** https://github.com/dreamvalleyrealty/dv-real-estate-accounting
- **Production URL:** https://bo.dvrealty.ca/
- **Primary branch:** `main`
- **Hosting:** DigitalOcean App Platform
- **Backend:** Supabase
- **Package version at handoff:** `84.6`

## Technology stack

- React 18 with JavaScript ES modules
- Vite 6 for development and production builds
- Node.js 22; Docker-based build and runtime
- Supabase JS client for database access and authentication
- jsPDF and pdf-lib for PDF generation and manipulation
- pdfjs-dist and Tesseract.js for PDF processing and OCR
- xlsx for spreadsheet processing
- lucide-react for icons
- Google Maps APIs for the Open House Signs module

### Build and runtime

- Build: `npm run build`
- Vite output: `dist/`
- Dockerfile builds the app, then runs `vite preview` on the supplied `PORT`.
- Frontend environment variables include `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_GOOGLE_MAPS_API_KEY`.

## Repository layout (confirmed paths)

```
.
├── src/
│   ├── lib/
│   │   └── supabase.js
│   ├── Transactions.jsx
│   ├── MoneyInput.jsx
│   ├── CommercialLeaseCommissionEditor.jsx
│   ├── SellerSettlements.jsx
│   ├── CommissionTrustTransfer.jsx
│   └── PreConstructionBuilderProfiles.jsx
├── supabase/
│   ├── migrations/
│   └── functions/
│       └── trust-account-information/
├── index.html
├── field.html
├── vite.config.js
├── Dockerfile
└── package.json
```

This is a partial map of paths confirmed during the handoff, not a complete directory inventory.

## Completed feature areas

The application has implemented work across:

- Brokerage transactions, commission calculations and payroll
- Agent and transaction administration
- Invoice generation and email composition
- Pre-construction builder profiles and billing details
- Trade document submission, review and signed trade record handling
- Trust accounting, banking reconciliation and commission trust transfers
- Seller settlements
- Commercial lease commission calculations
- PDF and spreadsheet processing
- Open House Signs with Google Maps integration
- Secure trust-account information sharing using encrypted records, expiring links, email OTP verification and audit logging
- Build-version injection from `package.json` through `vite.config.js`

Feature areas listed here reflect existing project work; this handoff does not certify that every workflow has passed current production testing.

## Current known issue: Email Builder Invoice

The **Email Builder Invoice** button in the transaction invoice preview was reported as not opening the email composer.

Two fixes have been committed to `main`:

1. [1824122 — Fix builder invoice email recipient from linked profile](https://github.com/dreamvalleyrealty/dv-real-estate-accounting/commit/1824122b4854edb93a227bebe732c93c2c08be2b)
   - Reads builder billing details from the linked builder profile as a fallback.
2. [74fdfe — Ensure builder invoice email composer always opens](https://github.com/dreamvalleyrealty/dv-real-estate-accounting/commit/74fdfece36306b59ad09d0f15a459bc2a1be7a1e)
   - Removes the early return that blocked the composer when the billing email was blank.
   - Shows a warning when the billing email is unavailable.
   - Normalizes the pre-construction and commission-payer checks.

**Status:** Code is committed. Deployment to DigitalOcean and production verification have not been confirmed. Do not describe this issue as fixed until tested on the live app.

## Other previously reported issues to recheck

The following were raised in earlier development work. Their present status is unverified:

- Commission payroll and bulk payment discrepancies
- HST and net commission mismatches
- Duplicate commission payment records
- Desk fee deductions appearing in transaction calculations
- Agent profile update permission errors
- Invoice supporting-document attachment workflow

## Exact next step

1. In DigitalOcean, open App Platform and select the app serving `bo.dvrealty.ca`.
2. Confirm its connected repository is `dreamvalleyrealty/dv-real-estate-accounting` and its branch is `main`.
3. Start a deployment of the latest `main` commit (currently including the two builder-invoice fixes).
4. Wait for the deployment to report successful.
5. Test a pre-construction transaction with a linked builder profile:
   - Open the invoice preview.
   - Click **Email Builder Invoice**.
   - Confirm the composer opens.
   - Confirm the builder billing email appears in the To field.
   - Confirm the invoice PDF is attached.
   - Send a test email and confirm delivery.

If the button still fails after deployment, inspect browser console errors and the failed network request, then trace the actual runtime failure in `src/Transactions.jsx`. Do not assume a deployment alone proves the issue is resolved.

## Development and release rules

- Use this repository: `dreamvalleyrealty/dv-real-estate-accounting`.
- Use `main` unless a separate branch is explicitly requested.
- Inspect the current implementation before editing.
- Preserve existing accounting rules and production data.
- Run `npm run build` and resolve build errors before release.
- Update `package.json` version for a release when appropriate; Vite injects this value as the build version.
- Never claim a deployment or production fix without confirming it in DigitalOcean and testing the live workflow.
