# Gemini Paperwork Audit

This Supabase Edge Function reviews temporary agent paperwork using the Google Gemini Developer API. It does not write uploaded files or audit results to Supabase tables or Storage.

## Required Supabase secret

Set `GEMINI_API_KEY` in **Supabase Dashboard → Edge Functions → Secrets** for the production project. The key must never be placed in frontend code, GitHub source, or a browser environment variable.

Optional:
- `GEMINI_MODEL`: defaults to `gemini-3.1-flash-lite`.

The default model is selected for low operating cost and currently has a free API tier subject to Google's quotas and availability. If the free quota is exhausted, the function returns a clear rate-limit message. It does not switch to a paid provider or automatically upgrade billing.

Keep JWT verification enabled. The function verifies the caller's Supabase session and requires an active `dv_accounting_user_profiles` record.

## Current limits

- Up to 8 documents per request.
- 4 MB combined original file size.
- PDF, JPG, PNG and WebP.
- The UI sends files in memory as base64 to the Edge Function.
- The Edge Function sends PDF/image data inline to Gemini for one request; it does not use Google's Files API or save files in Supabase Storage.
- The function does not save the response or document contents.

## Privacy warning

Google's Gemini API free tier states that submitted content may be used to improve Google's products. Do not use the free tier with confidential client agreements, identification, financial records, or live transaction packages unless the brokerage has reviewed and approved Google's applicable data terms. Use dummy or redacted paperwork for free-tier testing. Google's paid tier states that content is not used to improve its products, but paid use is not enabled by this implementation.

## Review design

The model returns structured JSON findings with document, page, category, severity, evidence, confidence and suggested action. It also reports cross-document comparisons. The UI keeps deterministic PDF-field and Document Library checks separate from AI findings.

AI output is advisory. It must not be treated as legal advice, RECO approval, proof that a form is complete, or authentication of a signature. Low-confidence or unclear handwriting/signature findings require human review.

## Deployment

Deploy this function with JWT verification enabled after the `GEMINI_API_KEY` secret is configured. The frontend invokes it using the signed-in Supabase session. Do not disable JWT verification to work around authentication errors.
