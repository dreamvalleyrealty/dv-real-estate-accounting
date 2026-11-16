# AI Paperwork Audit

This Edge Function reviews an agent's temporary paperwork package with the OpenAI Responses API. It does not write uploaded files or audit results to Supabase tables or Storage.

## Required Supabase secret

Set `OPENAI_API_KEY` in **Supabase Dashboard → Edge Functions → Secrets** for the production project. The key must never be placed in frontend code, GitHub source, or a browser environment variable.

Optional:
- `OPENAI_MODEL`: defaults to `gpt-4.1`.

Keep JWT verification enabled. The function verifies the caller's Supabase session and requires an active `dv_accounting_user_profiles` record.

## Current first-release limits

- Up to 8 documents per request.
- 4 MB combined original file size.
- PDF, JPG, PNG and WebP.
- The UI sends files in memory as base64 to the Edge Function.
- The Edge Function forwards them to OpenAI's Responses API as request inputs; it does not upload them to OpenAI's Files API or save them in Supabase Storage.
- The function does not save the response or document contents.

The OpenAI API processes the documents under the API account's applicable data controls and retention terms. Review those terms before enabling this feature for live client paperwork.

## Review design

The model returns structured JSON findings with document, page, category, severity, evidence, confidence and suggested action. It also reports cross-document comparisons. The UI keeps the deterministic PDF-field and Document Library checks separate from AI findings.

AI output is advisory. It must not be treated as legal advice, RECO approval, proof that a form is complete, or authentication of a signature. Low-confidence or unclear handwriting/signature findings require human review.

## Deployment

Deploy this function with JWT verification enabled after the `OPENAI_API_KEY` secret is configured. The frontend invokes it using the signed-in Supabase session. Do not disable JWT verification to work around authentication errors.
