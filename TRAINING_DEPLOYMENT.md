# Training Deployment (DigitalOcean)

This branch is intended for the isolated Dream Valley Realty training environment.

## Required environment variables

Configure these in the DigitalOcean App Platform app settings (Build-time Environment Variables):

- `VITE_SUPABASE_URL=https://mqnbifhhdhauuaqkvhbk.supabase.co`
- `VITE_SUPABASE_ANON_KEY=<training project's publishable/anon key>`

Use only the training project's public publishable/anon key. Never put a Supabase service-role key, database password, or other secret in Vite variables or committed files.

## DigitalOcean App Platform settings

For a static-site deployment:

- Repository: `dreamvalleyrealty/dv-real-estate-accounting`
- Branch: `training-digitalocean`
- Build command: `npm run build`
- Output directory: `dist`
- Node.js: 20 or a compatible supported version

Add a single-page-app fallback/rewrite from `/*` to `/index.html` if client-side routes require it.

## Isolation checklist

1. Confirm the URL and key point to the training Supabase project, not production.
2. Keep the training database separate; do not copy production transactions or personal information.
3. Confirm authentication, RLS policies, and core workflows with synthetic records before inviting staff.
4. Keep production's `main` branch unchanged while testing this branch.
5. Verify Railway's project branch/deploy settings separately before assuming it will not deploy this branch.

## Important

This file documents deployment settings only. It does not create or configure the DigitalOcean app, disable Railway deployments, or prove that the application has been deployed.
