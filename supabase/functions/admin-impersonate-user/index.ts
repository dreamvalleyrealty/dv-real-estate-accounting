import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("APP_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  const respond = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed." }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) return respond({ error: "Server auth configuration is incomplete." }, 500);

    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!token) return respond({ error: "Sign in as Super Admin first." }, 401);

    const callerClient = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: callerResult, error: callerError } = await callerClient.auth.getUser(token);
    if (callerError || !callerResult.user) {
      console.error("Caller token verification failed:", callerError?.message || "No user returned");
      return respond({ error: "Could not verify the signed-in user: " + (callerError?.message || "No user returned") }, 401);
    }

    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: callerProfile, error: profileError } = await admin.from("dv_accounting_user_profiles").select("role,active,display_name").eq("user_id", callerResult.user.id).maybeSingle();
    if (profileError) {
      console.error("Caller profile lookup failed:", profileError.message);
      return respond({ error: "Could not verify Super Admin profile: " + profileError.message }, 500);
    }
    const callerRole = String(callerProfile?.role || callerResult.user.app_metadata?.role || callerResult.user.user_metadata?.role || "").toUpperCase().replace(/[\s-]+/g, "_");
    if (!callerProfile || callerProfile.active === false || !["SUPERADMIN", "SUPER_ADMIN"].includes(callerRole)) return respond({ error: "Only an active Super Admin can impersonate another account." }, 403);

    let targetUserId = "";
    try { targetUserId = String((await req.json())?.target_user_id || "").trim(); } catch { return respond({ error: "A target account is required." }, 400); }
    if (!targetUserId || targetUserId === callerResult.user.id) return respond({ error: "Choose a different agent or staff account." }, 400);

    const { data: targetProfile, error: targetProfileError } = await admin.from("dv_accounting_user_profiles").select("user_id,email,display_name,role,active").eq("user_id", targetUserId).maybeSingle();
    if (targetProfileError) {
      console.error("Target profile lookup failed:", targetProfileError.message);
      return respond({ error: "Could not read target account: " + targetProfileError.message }, 500);
    }
    if (!targetProfile) return respond({ error: "Target login was not found." }, 404);
    if (targetProfile.active === false) return respond({ error: "Inactive accounts cannot be impersonated." }, 403);
    const targetRole = String(targetProfile.role || "").toUpperCase().replace(/[\s-]+/g, "_");
    if (!["AGENT", "STAFF", "ACCOUNTANT", "VIEWER", "MANAGER", "ADMIN"].includes(targetRole)) return respond({ error: "Only agent and staff-type accounts can be impersonated." }, 403);
    const targetEmail = String(targetProfile.email || "").trim().toLowerCase();
    if (!targetEmail) return respond({ error: "The target account has no login email." }, 400);

    const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email: targetEmail });
    const tokenHash = linkData?.properties?.hashed_token;
    if (linkError || !tokenHash) {
      console.error("Temporary login link generation failed:", linkError?.message || "No hashed token returned");
      return respond({ error: "Could not create a temporary target session: " + (linkError?.message || "No verification token returned.") }, 500);
    }

    // Use the audit table's actual schema: allowed actions are INSERT/UPDATE/DELETE, and there is no user_id column.
    const { error: auditError } = await admin.from("dv_accounting_audit_log").insert({
      table_name: "auth.users",
      record_id: { id: targetUserId },
      action: "INSERT",
      actor_id: callerResult.user.id,
      actor_email: callerResult.user.email || null,
      actor_name: callerProfile.display_name || callerResult.user.user_metadata?.full_name || callerResult.user.email || "Super Admin",
      changed_at: new Date().toISOString(),
      old_data: null,
      new_data: { event: "USER_IMPERSONATION_STARTED", target_email: targetEmail, target_name: targetProfile.display_name || targetEmail, target_role: targetRole, method: "verified_magiclink_session", started_at: new Date().toISOString() },
    });
    if (auditError) {
      console.error("Impersonation audit insert failed:", auditError.message);
      return respond({ error: "Impersonation was not started because the audit entry failed: " + auditError.message }, 500);
    }

    return respond({ token_hash: tokenHash, target: { user_id: targetUserId, email: targetEmail, display_name: targetProfile.display_name || targetEmail, role: targetRole } });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("admin-impersonate-user unexpected error:", message);
    return respond({ error: "Unexpected impersonation error: " + message }, 500);
  }
});