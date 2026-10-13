import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const allowedRoles = new Set(["ADMIN", "MANAGER", "STAFF", "ACCOUNTANT", "VIEWER", "AGENT"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...cors, "Content-Type": "application/json" } });

  let createdUserId: string | null = null;
  let createdAgentId: string | null = null;
  let createdEmployeeId: string | null = null;
  try {
    const authorization = req.headers.get("Authorization") || "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceKey) throw new Error("Supabase server configuration is incomplete.");

    const callerClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data: { user: caller }, error: authError } = await callerClient.auth.getUser();
    if (authError || !caller) throw new Error("Sign in again before creating a user.");

    const { data: callerRole, error: roleError } = await callerClient.rpc("dv_accounting_current_user_role");
    if (roleError || String(callerRole || "").toUpperCase() !== "SUPERADMIN") {
      throw new Error("Only a Super Admin can create login accounts.");
    }

    const body = await req.json();
    const displayName = String(body?.display_name || "").trim().slice(0, 120);
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.temporary_password || "");
    const role = String(body?.role || "STAFF").trim().toUpperCase();
    const agentId = String(body?.agent_id || "").trim() || null;
    const employeeId = String(body?.employee_id || "").trim() || null;

    if (!displayName) throw new Error("Enter the user's full name.");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error("Enter a valid email address.");
    if (password.length < 8) throw new Error("Temporary password must be at least 8 characters.");
    if (!allowedRoles.has(role)) throw new Error("Select a permitted role. Super Admin accounts cannot be created from this form.");
    if (role === "AGENT" && !agentId) throw new Error("Select the agent record to link to this login.");
    if (role !== "AGENT" && agentId) throw new Error("Only an Agent role can be linked to an agent record.");
    if (role === "AGENT" && employeeId) throw new Error("An Agent login must be linked through the agent record, not a payroll staff record.");

    const admin = createClient(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
    let agent: { id: string; email: string | null; name: string | null; first_name: string | null; last_name: string | null; user_id?: string | null } | null = null;
    let employee: { id: string; email: string | null; name: string | null; user_id?: string | null } | null = null;
    if (agentId) {
      const { data, error } = await admin.from("dv_accounting_agents").select("id,email,name,first_name,last_name,user_id").eq("id", agentId).maybeSingle();
      if (error) throw error;
      if (!data) throw new Error("The selected agent record could not be found.");
      if (String(data.email || "").trim().toLowerCase() !== email) throw new Error("The login email must match the selected agent's email address.");
      if (data.user_id) throw new Error("This agent is already linked to a login account.");
      agent = data;
    }
    if (employeeId) {
      const { data, error } = await admin.from("dv_accounting_employees").select("id,email,name,user_id").eq("id", employeeId).maybeSingle();
      if (error) throw error;
      if (!data) throw new Error("The selected payroll staff record could not be found.");
      if (String(data.email || "").trim().toLowerCase() !== email) throw new Error("The login email must match the payroll staff email address.");
      if (data.user_id) throw new Error("This payroll staff member is already linked to a login account.");
      employee = data;
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      app_metadata: { role, ...(agentId ? { agent_id: agentId } : {}), ...(employeeId ? { employee_id: employeeId } : {}) },
      user_metadata: { display_name: displayName, ...(agentId ? { agent_id: agentId } : {}), ...(employeeId ? { employee_id: employeeId } : {}), must_change_password: true },
    });
    if (createError) throw createError;
    if (!created.user?.id) throw new Error("Supabase did not return the new user ID.");
    createdUserId = created.user.id;

    const { error: profileError } = await admin.from("dv_accounting_user_profiles").insert({
      user_id: createdUserId,
      display_name: displayName,
      email,
      role,
      active: true,
    });
    if (profileError) throw profileError;

    if (agent) {
      const { data: linked, error: linkError } = await admin.from("dv_accounting_agents").update({ user_id: createdUserId }).eq("id", agent.id).is("user_id", null).select("id").maybeSingle();
      if (linkError) throw linkError;
      if (!linked) throw new Error("The login was created but the agent link could not be verified. Please contact the Super Admin.");
      createdAgentId = agent.id;
    }
    if (employee) {
      const { data: linked, error: linkError } = await admin.from("dv_accounting_employees").update({ user_id: createdUserId }).eq("id", employee.id).is("user_id", null).select("id").maybeSingle();
      if (linkError) throw linkError;
      if (!linked) throw new Error("The login was created but the payroll staff link could not be verified. Please contact the Super Admin.");
      createdEmployeeId = employee.id;
    }

    return new Response(JSON.stringify({ ok: true, user_id: createdUserId, email, role, must_change_password: true }), {
      status: 200, headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (error) {
    if (createdUserId) {
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      if (supabaseUrl && serviceKey) {
        const admin = createClient(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
        await admin.from("dv_accounting_user_profiles").delete().eq("user_id", createdUserId);
        if (createdAgentId) await admin.from("dv_accounting_agents").update({ user_id: null }).eq("id", createdAgentId).eq("user_id", createdUserId);
        if (createdEmployeeId) await admin.from("dv_accounting_employees").update({ user_id: null }).eq("id", createdEmployeeId).eq("user_id", createdUserId);
        await admin.auth.admin.deleteUser(createdUserId);
      }
    }
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
  }
});