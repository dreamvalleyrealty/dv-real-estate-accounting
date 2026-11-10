import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_ORIGIN = "https://bo.dvrealty.ca";
const corsHeaders = {
  "Access-Control-Allow-Origin": APP_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin"
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" }
  });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "Sign in required" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const clientId = Deno.env.get("CANVA_CLIENT_ID");
    const clientSecret = Deno.env.get("CANVA_CLIENT_SECRET");
    if (!supabaseUrl || !serviceKey || !clientId || !clientSecret) return json({ error: "Canva is not configured on the server." }, 503);

    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !authData.user) return json({ error: "Your session has expired. Sign in again." }, 401);

    const { data: profile, error: profileError } = await admin.from("dv_accounting_user_profiles")
      .select("role,active").eq("user_id", authData.user.id).maybeSingle();
    if (profileError || !profile?.active || !["ADMIN", "SUPERADMIN"].includes(String(profile.role || "").toUpperCase())) {
      return json({ error: "Only an active administrator can sync Canva templates." }, 403);
    }

    const { data: integration, error: integrationError } = await admin.from("dv_accounting_private_integrations")
      .select("secret_payload").eq("integration_key", "canva").maybeSingle();
    if (integrationError || !integration?.secret_payload?.refresh_token) return json({ error: "Canva is not connected. Connect Canva first." }, 409);

    const oldRefreshToken = integration.secret_payload.refresh_token;
    const tokenResponse = await fetch("https://api.canva.com/rest/v1/oauth/token", {
      method: "POST",
      headers: {
        "Authorization": "Basic " + btoa(clientId + ":" + clientSecret),
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json"
      },
      body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: oldRefreshToken })
    });
    const tokenData = await tokenResponse.json().catch(() => ({}));
    if (!tokenResponse.ok || !tokenData.access_token) {
      console.error("Canva refresh failed", tokenResponse.status, tokenData.error || "unknown");
      return json({ error: "Canva authorization expired or was revoked. Reconnect Canva from Design & Artwork." }, 409);
    }

    const nextRefreshToken = tokenData.refresh_token || oldRefreshToken;
    if (nextRefreshToken !== oldRefreshToken) {
      const nextPayload = { ...integration.secret_payload, refresh_token: nextRefreshToken, refreshed_at: new Date().toISOString() };
      const { error: saveTokenError } = await admin.from("dv_accounting_private_integrations")
        .update({ secret_payload: nextPayload, updated_at: new Date().toISOString(), updated_by: authData.user.id })
        .eq("integration_key", "canva");
      if (saveTokenError) throw saveTokenError;
    }

    const templates: any[] = [];
    let continuation: string | undefined;
    let pageCount = 0;
    do {
      const listUrl = new URL("https://api.canva.com/rest/v1/brand-templates");
      listUrl.searchParams.set("limit", "100");
      if (continuation) listUrl.searchParams.set("continuation", continuation);
      const response = await fetch(listUrl, { headers: { "Authorization": "Bearer " + tokenData.access_token, "Accept": "application/json" } });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        console.error("Canva brand template list failed", response.status, body.code || body.error || "unknown");
        const message = response.status === 403
          ? "Canva did not allow access to Brand Templates. Check the connected Canva account plan and brandtemplate:meta:read permission."
          : "Canva could not return the Brand Template library. Try again.";
        return json({ error: message, canva_status: response.status }, 502);
      }
      if (Array.isArray(body.items)) templates.push(...body.items);
      continuation = body.continuation || undefined;
      pageCount++;
    } while (continuation && pageCount < 10);

    const rows = await Promise.all(templates.map(async (item: any) => {
      let dataset: Record<string, unknown> = {};
      try {
        const datasetResponse = await fetch("https://api.canva.com/rest/v1/brand-templates/" + encodeURIComponent(item.id) + "/dataset", {
          headers: { "Authorization": "Bearer " + tokenData.access_token, "Accept": "application/json" }
        });
        if (datasetResponse.ok) {
          const datasetBody = await datasetResponse.json().catch(() => ({}));
          dataset = datasetBody.dataset && typeof datasetBody.dataset === "object" ? datasetBody.dataset : {};
        }
      } catch (error) {
        console.error("Could not inspect Canva template dataset", item.id);
      }
      return {
        canva_template_id: item.id,
        title: item.title || "Untitled Canva template",
        view_url: item.view_url || null,
        create_url: item.create_url || null,
        can_autofill: Object.keys(dataset).length > 0,
        dataset,
        canva_created_at: item.created_at || null,
        canva_updated_at: item.updated_at || null,
        synced_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      };
    })).filter((item: any) => item.canva_template_id);

    if (rows.length) {
      const { error: upsertError } = await admin.from("dv_accounting_canva_templates")
        .upsert(rows, { onConflict: "canva_template_id", ignoreDuplicates: false });
      if (upsertError) throw upsertError;
    }

    return json({ success: true, synced: rows.length, pages: pageCount, message: rows.length ? "Canva templates synced." : "No Brand Templates were found in the connected Canva account." });
  } catch (error) {
    console.error("Canva template sync error", error instanceof Error ? error.message : "unknown");
    return json({ error: "Could not sync Canva templates. Please try again." }, 500);
  }
});