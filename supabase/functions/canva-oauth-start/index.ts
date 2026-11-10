import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_ORIGIN = "https://bo.dvrealty.ca";
const REDIRECT_URI = "https://bjriisauroukyuhbfkuh.supabase.co/functions/v1/canva-oauth-callback";
const SCOPES = [
  "asset:read", "asset:write",
  "brandtemplate:content:read", "brandtemplate:meta:read",
  "design:content:read", "design:content:write", "design:meta:read",
  "profile:read"
].join(" ");

const corsHeaders = {
  "Access-Control-Allow-Origin": APP_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin"
};

function randomBase64Url(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
async function sha256Base64Url(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  let binary = "";
  for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId = Deno.env.get("CANVA_CLIENT_ID");
    const clientSecret = Deno.env.get("CANVA_CLIENT_SECRET");
    if (!supabaseUrl || !serviceKey || !clientId || !clientSecret) {
      return new Response(JSON.stringify({ error: "Canva integration is not configured on the server" }), { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !authData.user) return new Response(JSON.stringify({ error: "Your session is invalid. Please sign in again." }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });

    const { data: profile, error: profileError } = await admin
      .from("dv_accounting_user_profiles")
      .select("role, active")
      .eq("user_id", authData.user.id)
      .maybeSingle();
    if (profileError || !profile?.active || !["ADMIN", "SUPERADMIN"].includes(String(profile.role || "").toUpperCase())) {
      return new Response(JSON.stringify({ error: "Only an active administrator can connect Canva." }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const state = randomBase64Url(32);
    const verifier = randomBase64Url(64);
    const challenge = await sha256Base64Url(verifier);
    const stateHash = await sha256Base64Url(state);
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

    const { error: insertError } = await admin.from("dv_accounting_canva_oauth_states").insert({
      state_hash: stateHash,
      code_verifier: verifier,
      user_id: authData.user.id,
      expires_at: expiresAt
    });
    if (insertError) throw insertError;

    const authUrl = new URL("https://www.canva.com/api/oauth/authorize");
    authUrl.searchParams.set("code_challenge", challenge);
    authUrl.searchParams.set("code_challenge_method", "s256");
    authUrl.searchParams.set("scope", SCOPES);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("client_id", clientId);
    authUrl.searchParams.set("state", state);
    authUrl.searchParams.set("redirect_uri", REDIRECT_URI);

    return new Response(JSON.stringify({ authorization_url: authUrl.toString() }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" }
    });
  } catch (error) {
    console.error("Canva OAuth start error:", error instanceof Error ? error.message : "unknown");
    return new Response(JSON.stringify({ error: "Could not start Canva authorization." }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});