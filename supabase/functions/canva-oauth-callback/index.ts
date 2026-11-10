import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const REDIRECT_URI = "https://bjriisauroukyuhbfkuh.supabase.co/functions/v1/canva-oauth-callback";
const APP_URL = "https://bo.dvrealty.ca";

function resultPage(ok: boolean, code: string) {
  const title = ok ? "Canva connected" : "Canva connection not completed";
  const message = ok
    ? "Dream Valley Back Office has been connected to Canva. You can close this page and return to Back Office."
    : "Canva could not be connected. Return to Back Office and try again. If the issue continues, contact your administrator.";
  const url = new URL(APP_URL);
  url.searchParams.set("canva", ok ? "connected" : "error");
  if (!ok) url.searchParams.set("reason", code);
  return new Response(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title></head><body style="font:16px system-ui;max-width:620px;margin:64px auto;padding:0 24px;color:#0f2141"><h2>${title}</h2><p>${message}</p><p><a style="color:#9e8556" href="${url.toString()}">Return to Dream Valley Back Office</a></p></body></html>`, {
    status: ok ? 200 : 400,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" }
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET") return resultPage(false, "method_not_allowed");
  const url = new URL(req.url);
  const oauthError = url.searchParams.get("error");
  if (oauthError) return resultPage(false, "authorization_denied");
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state) return resultPage(false, "missing_callback_parameters");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const clientId = Deno.env.get("CANVA_CLIENT_ID");
  const clientSecret = Deno.env.get("CANVA_CLIENT_SECRET");
  if (!supabaseUrl || !serviceKey || !clientId || !clientSecret) return resultPage(false, "server_configuration");

  try {
    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const stateDigest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(state));
    let binary = "";
    for (const byte of new Uint8Array(stateDigest)) binary += String.fromCharCode(byte);
    const stateHash = btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

    const { data: pending, error: stateError } = await admin
      .from("dv_accounting_canva_oauth_states")
      .update({ consumed_at: new Date().toISOString() })
      .eq("state_hash", stateHash)
      .is("consumed_at", null)
      .gt("expires_at", new Date().toISOString())
      .select("code_verifier, user_id")
      .maybeSingle();

    if (stateError || !pending) return resultPage(false, "invalid_or_expired_state");

    const credentials = btoa(`${clientId}:${clientSecret}`);
    const tokenResponse = await fetch("https://api.canva.com/rest/v1/oauth/token", {
      method: "POST",
      headers: {
        "Authorization": `Basic ${credentials}`,
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json"
      },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code,
        redirect_uri: REDIRECT_URI,
        code_verifier: pending.code_verifier
      })
    });

    const tokenBody = await tokenResponse.json().catch(() => ({}));
    if (!tokenResponse.ok || !tokenBody.access_token || !tokenBody.refresh_token) {
      console.error("Canva token exchange failed:", tokenResponse.status, tokenBody.error || "token_response_invalid");
      return resultPage(false, "token_exchange_failed");
    }

    const scopes = typeof tokenBody.scope === "string" ? tokenBody.scope : "";
    const payload = {
      refresh_token: tokenBody.refresh_token,
      token_type: tokenBody.token_type || "Bearer",
      expires_in: Number(tokenBody.expires_in || 14400),
      granted_scopes: scopes,
      connected_at: new Date().toISOString(),
      connected_by: pending.user_id
    };

    const { error: saveError } = await admin.from("dv_accounting_private_integrations").upsert({
      integration_key: "canva",
      secret_payload: payload,
      updated_at: new Date().toISOString(),
      updated_by: pending.user_id
    }, { onConflict: "integration_key" });

    if (saveError) {
      console.error("Canva token storage failed:", saveError.message);
      return resultPage(false, "secure_token_storage_failed");
    }

    return resultPage(true, "connected");
  } catch (error) {
    console.error("Canva OAuth callback error:", error instanceof Error ? error.message : "unknown");
    return resultPage(false, "callback_processing_failed");
  }
});