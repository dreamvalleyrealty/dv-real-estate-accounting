import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") || "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const callerClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
    const { data: { user: caller }, error: callerError } = await callerClient.auth.getUser();
    if (callerError || !caller) throw new Error("Not authenticated.");
    const role = String(caller.app_metadata?.role || caller.user_metadata?.role || "").toUpperCase();
    if (!["SUPERADMIN"].includes(role)) throw new Error("Only a Super Admin can create or reset an agent's temporary password.");

    const body = await req.json();
    const agentId = String(body?.agent_id || "").trim();
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "");
    if (!agentId || !email || password.length < 8) throw new Error("Agent, email and a temporary password of at least 8 characters are required.");

    const admin = createClient(supabaseUrl, serviceKey);
    const { data: agent, error: agentError } = await admin.from("dv_accounting_agents").select("id,email,first_name,last_name").eq("id", agentId).maybeSingle();
    if (agentError) throw agentError;
    if (!agent) throw new Error("Agent record not found.");
    if (String(agent.email || "").trim().toLowerCase() !== email) throw new Error("The login email must match the agent's email.");

    const { data: existing } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    const found = existing?.users?.find(u => String(u.email || "").trim().toLowerCase() === email);
    let authUserId = found?.id;
    if (found) {
      const { error } = await admin.auth.admin.updateUserById(found.id, {
        password,
        email_confirm: true,
        app_metadata: { ...(found.app_metadata || {}), role: "AGENT", agent_id: agentId },
        user_metadata: { ...(found.user_metadata || {}), agent_id: agentId, must_change_password: true },
      });
      if (error) throw error;
    } else {
      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        app_metadata: { role: "AGENT", agent_id: agentId },
        user_metadata: { agent_id: agentId, must_change_password: true },
      });
      if (error) throw error;
      authUserId = data.user?.id;
    }
    if (!authUserId) throw new Error("Could not create the authentication account.");
    return new Response(JSON.stringify({ ok: true, user_id: authUserId, email, must_change_password: true }), { status: 200, headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
