import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const encoder = new TextEncoder();
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
});
const validEmail = (value: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
const bytesToHex = (value: Uint8Array) => [...value].map((v) => v.toString(16).padStart(2, "0")).join("");
const randomHex = (length: number) => {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytesToHex(bytes);
};
async function sha256(value: string) {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}
async function encrypt(value: string, secret: string) {
  const keyBytes = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(value)));
  const output = new Uint8Array(iv.length + encrypted.length);
  output.set(iv, 0); output.set(encrypted, iv.length);
  return output;
}
async function decrypt(value: Uint8Array, secret: string) {
  const keyBytes = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  const iv = value.slice(0, 12), ciphertext = value.slice(12);
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ciphertext));
}
function htmlEscape(value: string) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}
async function getZohoSecrets(admin: any) {
  const clientId = Deno.env.get("ZOHO_CLIENT_ID");
  const clientSecret = Deno.env.get("ZOHO_CLIENT_SECRET");
  if (!clientId || !clientSecret) throw new Error("Zoho email service is not configured.");
  const { data, error } = await admin.from("dv_accounting_private_integrations")
    .select("secret_payload").eq("integration_key", "zoho_mail").maybeSingle();
  if (error || !data?.secret_payload?.refresh_token) throw new Error("Zoho Mail is not connected. Reconnect the mailbox first.");
  const p = data.secret_payload;
  const accountsServer = String(p.accounts_server || "https://accounts.zoho.com");
  const mailBase = String(p.mail_api_base || "https://mail.zoho.com");
  const from = String(p.sender_email || "admin@dvrealty.ca");
  const refresh = await fetch(accountsServer + "/oauth/v2/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ refresh_token: p.refresh_token, client_id: clientId, client_secret: clientSecret, grant_type: "refresh_token" }),
  });
  const token = await refresh.json().catch(() => ({}));
  if (!refresh.ok || !token.access_token) throw new Error("Zoho token refresh failed. Reconnect Zoho Mail.");
  const headers = { Authorization: "Zoho-oauthtoken " + token.access_token, Accept: "application/json" };
  const accountsResponse = await fetch(mailBase + "/api/accounts", { headers });
  const accountsJson = await accountsResponse.json().catch(() => ({}));
  if (!accountsResponse.ok) throw new Error("Could not access Zoho Mail accounts.");
  const list = Array.isArray(accountsJson?.data) ? accountsJson.data : Array.isArray(accountsJson) ? accountsJson : [];
  const account = list.find((a: any) => String(a.accountAddress || a.emailAddress || a.primaryEmailAddress || a.email || "").toLowerCase() === from.toLowerCase())
    || list.find((a: any) => String(a.accountName || "").toLowerCase().includes("admin")) || list[0];
  const accountId = account?.accountId || account?.account_id || account?.id;
  if (!accountId) throw new Error("Zoho returned no usable sender account.");
  return { mailBase, headers, accountId: String(accountId), from };
}
async function sendZoho(admin: any, to: string, subject: string, body: string) {
  const z = await getZohoSecrets(admin);
  const response = await fetch(z.mailBase + "/api/accounts/" + encodeURIComponent(z.accountId) + "/messages", {
    method: "POST",
    headers: { ...z.headers, "Content-Type": "application/json" },
    body: JSON.stringify({ fromAddress: z.from, toAddress: to, subject, content: body, mailFormat: "html" }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || (result?.status?.code && Number(result.status.code) >= 400)) {
    throw new Error("Zoho rejected the email request (HTTP " + response.status + ").");
  }
  return result?.data?.messageId || result?.data?.message_id || result?.messageId || null;
}
async function requireActor(req: Request, admin: any, supabaseUrl: string, anonKey: string) {
  const authorization = req.headers.get("Authorization") || "";
  if (!authorization.startsWith("Bearer ")) throw new Error("Sign in before using trust account information.");
  const callerClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: { user }, error } = await callerClient.auth.getUser();
  if (error || !user) throw new Error("Your session could not be verified. Please sign in again.");
  const { data: profile, error: profileError } = await admin.from("dv_accounting_user_profiles")
    .select("role,active").eq("user_id", user.id).maybeSingle();
  if (profileError || profile?.active === false) throw new Error("Your active user role could not be verified.");

  const metadataRole = String(user.app_metadata?.role || user.app_metadata?.user_role || "").toUpperCase();
  const profileRole = String(profile?.role || "").toUpperCase();
  const roleCandidate = profileRole || metadataRole || "STAFF";
  const isAdmin = ["SUPERADMIN","ADMIN"].includes(roleCandidate);
  const email = String(user.email || "").trim().toLowerCase();
  let linkedAgent: any = null;
  const metadataAgentId = String(user.app_metadata?.agent_id || user.user_metadata?.agent_id || "").trim();
  if (metadataAgentId) {
    const { data, error: agentError } = await admin.from("dv_accounting_agents")
      .select("id,user_id,email,active").eq("id", metadataAgentId).maybeSingle();
    if (agentError) throw new Error("Could not verify the linked agent record.");
    if (data) linkedAgent = data;
  }
  if (!linkedAgent) {
    const { data, error: agentError } = await admin.from("dv_accounting_agents")
      .select("id,user_id,email,active").eq("user_id", user.id).maybeSingle();
    if (agentError) throw new Error("Could not verify the linked agent record.");
    if (data) linkedAgent = data;
  }
  if (!linkedAgent && email) {
    const { data, error: agentError } = await admin.from("dv_accounting_agents")
      .select("id,user_id,email,active").ilike("email", email).limit(2);
    if (agentError) throw new Error("Could not verify the linked agent record.");
    if (data?.length === 1) linkedAgent = data[0];
  }
  const isLinkedAgent = !!linkedAgent
    && linkedAgent.active !== false
    && (!linkedAgent.user_id || String(linkedAgent.user_id) === user.id)
    && String(linkedAgent.email || "").trim().toLowerCase() === email;
  // An AGENT role alone is insufficient; it must be backed by the matching agent record.
  const role = isAdmin ? roleCandidate : isLinkedAgent ? "AGENT" : roleCandidate === "AGENT" ? "STAFF" : roleCandidate;
  return { user, role };
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const encryptionSecret = Deno.env.get("TRUST_ACCOUNT_ENCRYPTION_KEY");
  const publicAppUrl = Deno.env.get("TRUST_ACCOUNT_PUBLIC_URL") || Deno.env.get("APP_URL");
  if (!supabaseUrl || !anonKey || !serviceKey || !encryptionSecret || !publicAppUrl) {
    return json({ error: "Secure trust account service is not fully configured. Set TRUST_ACCOUNT_ENCRYPTION_KEY and TRUST_ACCOUNT_PUBLIC_URL." }, 503);
  }
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid request body." }, 400); }
  const action = String(body?.action || "");
  try {
    if (["request_otp","verify_otp","view_details"].includes(action)) {
      const token = String(body.token || "");
      if (!/^[a-f0-9]{64}$/i.test(token)) return json({ error: "This secure link is invalid or expired." }, 400);
      const tokenHash = await sha256(token);
      const { data: log, error } = await admin.from("dv_accounting_trust_info_email_log").select("*").eq("token_hash", tokenHash).maybeSingle();
      const expectedStatus = action === "view_details" ? "VERIFIED" : "SENT";
      if (error || !log || log.status !== expectedStatus || new Date(log.link_expires_at).getTime() <= Date.now()) return json({ error: "This secure link is invalid or expired." }, 410);
      if (action === "verify_otp") {
        const otp = String(body.otp || "").trim();
        if (!log.recipient_email || log.recipient_email.length > 254) return json({ error: "This secure link is invalid or expired." }, 410);
        if (!/^\d{6}$/.test(otp)) return json({ error: "Enter the six-digit code." }, 400);
        if (!log.otp_hash || !log.otp_expires_at || new Date(log.otp_expires_at).getTime() <= Date.now()) return json({ error: "The code has expired. Ask the sender to issue a new secure link." }, 410);
        if (Number(log.otp_attempts || 0) >= 5) return json({ error: "Too many attempts. Ask the sender to issue a new secure link." }, 429);
        if (await sha256(token + ":" + otp) !== log.otp_hash) {
          await admin.from("dv_accounting_trust_info_email_log").update({ otp_attempts: Number(log.otp_attempts || 0) + 1 }).eq("id", log.id);
          return json({ error: "The code does not match. Check the email and try again." }, 401);
        }
        await admin.from("dv_accounting_trust_info_email_log").update({ status: "VERIFIED", token_verified: true, verified_at: new Date().toISOString() }).eq("id", log.id);
        return json({ ok: true, verified: true });
      }
      if (action === "request_otp") {
        if (log.token_verified) return json({ error: "This secure link has already been verified." }, 409);
        if (log.otp_sent_at && Date.now() - new Date(log.otp_sent_at).getTime() < 60_000) return json({ error: "Please wait one minute before requesting another code." }, 429);
        const otp = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
        const otpHtml = "<div style=\"font-family:Arial,sans-serif;max-width:620px;color:#172b4d\"><h2>Your verification code</h2><p>Hello " + htmlEscape(log.recipient_name) + ",</p><p>Your one-time code is:</p><p style=\"font-size:30px;font-weight:bold;letter-spacing:6px\">" + otp + "</p><p>This code expires in 15 minutes. Do not share it with anyone.</p></div>";
        const { error: updateOtpError } = await admin.from("dv_accounting_trust_info_email_log").update({
          otp_hash: await sha256(token + ":" + otp),
          otp_expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
          otp_sent_at: new Date().toISOString(),
          otp_attempts: 0,
        }).eq("id", log.id);
        if (updateOtpError) throw updateOtpError;
        try {
          await sendZoho(admin, log.recipient_email, "Your Dream Valley Realty verification code", otpHtml);
          return json({ ok: true, message: "A verification code has been sent to the email address this link was issued to." });
        } catch (sendError) {
          await admin.from("dv_accounting_trust_info_email_log").update({ otp_hash: null, otp_expires_at: null }).eq("id", log.id);
          throw sendError;
        }
      }
      if (!log.token_verified) return json({ error: "Verify your email code before viewing the banking instructions." }, 403);
      if (new Date(log.link_expires_at).getTime() <= Date.now()) return json({ error: "This secure link has expired." }, 410);
      if (log.opened_at) return json({ error: "These banking instructions have already been viewed. Request a new secure link if you need access again." }, 410);
      const { data: instructions, error: instructionError } = await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,transit_number,account_number_ciphertext,account_name,bank_address")
        .in("account_type", log.account_types);
      if (instructionError || !instructions?.length) return json({ error: "Banking instructions are not available." }, 503);
      const result = [];
      for (const item of instructions) {
        let encrypted: Uint8Array;
        let accountNumber: string;
        try {
          const raw = item.account_number_ciphertext;
          if (raw instanceof Uint8Array) encrypted = raw;
          else if (Array.isArray(raw)) encrypted = new Uint8Array(raw);
          else {
            const encoded = String(raw || "");
            const hex = encoded.startsWith("\\x") ? encoded.slice(2) : encoded;
            if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) throw new Error("Invalid encrypted account data.");
            encrypted = new Uint8Array(hex.length / 2);
            for (let i = 0; i < encrypted.length; i++) encrypted[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
          }
          accountNumber = await decrypt(encrypted, encryptionSecret);
        } catch {
          return json({ error: "Banking instructions could not be decrypted." }, 500);
        }
        result.push({ account_type: item.account_type, institution: item.institution, transit_number: item.transit_number, account_number: accountNumber, account_name: item.account_name, bank_address: item.bank_address });
      }
      // Claim the one-time view atomically so two concurrent requests cannot both release the details.
      const { data: claimed, error: claimError } = await admin.from("dv_accounting_trust_info_email_log")
        .update({ status: "VIEWED", opened_at: new Date().toISOString() })
        .eq("id", log.id).is("opened_at", null).eq("token_verified", true).select("id").maybeSingle();
      if (claimError || !claimed) return json({ error: "These banking instructions have already been viewed. Request a new secure link if you need access again." }, 409);
      return json({ accounts: result });
    }

    const actor = await requireActor(req, admin, supabaseUrl, anonKey);
    const isAdmin = ["SUPERADMIN","ADMIN"].includes(actor.role);
    if (action === "get_settings") {
      if (!isAdmin) return json({ error: "Only an administrator can view the saved banking instructions." }, 403);
      const { data, error } = await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,transit_number,account_name,bank_address,updated_at");
      if (error) throw error;
      // Return metadata only. The full account number is never sent back to the browser.
      const accounts: any = {};
      for (const row of data || []) accounts[row.account_type === "REAL_ESTATE_TRUST" ? "real_estate_trust" : "commission_trust"] = {
        institution: row.institution, transit_number: row.transit_number, account_name: row.account_name,
        bank_address: row.bank_address, account_number: "",
      };
      return json({ accounts });
    }
    if (action === "save_settings") {
      if (!isAdmin) return json({ error: "Only an administrator can update trust banking instructions." }, 403);
      const accounts = body.accounts || {};
      const updates = [];
      const seenTypes = [];
      for (const [key, type] of [["real_estate_trust","REAL_ESTATE_TRUST"],["commission_trust","COMMISSION_TRUST"]] as const) {
        const row = accounts[key] || {};
        const institution = String(row.institution || "").trim();
        const transit = String(row.transit_number || "").trim();
        const accountName = String(row.account_name || "").trim();
        const accountNumber = String(row.account_number || "").trim();
        if (!institution || !transit || !accountName) return json({ error: "Complete the institution, transit number, and account name for both trust accounts." }, 400);
        seenTypes.push(type);
        if (!/^\d{5}$/.test(transit)) return json({ error: "Enter a five-digit transit number." }, 400);
        if (accountNumber) {
          if (!/^\d{5,20}$/.test(accountNumber)) return json({ error: "Enter an account number containing 5–20 digits." }, 400);
          const cipher = await encrypt(accountNumber, encryptionSecret);
          updates.push({ account_type: type, institution, transit_number: transit, account_number_ciphertext: "\\x" + bytesToHex(cipher), account_name: accountName, bank_address: String(row.bank_address || "").trim() || null, updated_at: new Date().toISOString(), updated_by: actor.user.id });
        } else {
          const { data: existing, error: readError } = await admin.from("dv_accounting_trust_account_instructions")
            .select("account_type").eq("account_type", type).maybeSingle();
          if (readError || !existing) return json({ error: "Enter the full account number the first time this trust account is configured." }, 400);
          // Update only non-secret fields. The encrypted account number remains untouched.
          const { error: updateError } = await admin.from("dv_accounting_trust_account_instructions")
            .update({ institution, transit_number: transit, account_name: accountName, bank_address: String(row.bank_address || "").trim() || null, updated_at: new Date().toISOString(), updated_by: actor.user.id })
            .eq("account_type", type);
          if (updateError) throw updateError;
        }
      }
      if (seenTypes.length !== 2) return json({ error: "Both trust account records must be provided." }, 400);
      for (const update of updates) {
        const { error } = await admin.from("dv_accounting_trust_account_instructions").upsert(update, { onConflict: "account_type" });
        if (error) throw error;
      }
      return json({ ok: true, message: "Both trust account instructions were saved securely." });
    }
    if (action === "get_history") {
      const isAdmin = ["SUPERADMIN","ADMIN"].includes(actor.role);
      const isAgent = actor.role === "AGENT";
      if (!isAdmin && !isAgent) return json({ error: "You do not have access to trust information sharing history." }, 403);
      let query = admin.from("dv_accounting_trust_info_email_log")
        .select("id,recipient_name,recipient_email,account_types,status,sent_by,sent_by_email,created_at,sent_at,link_expires_at,verified_at,opened_at,error_message");
      if (!isAdmin) query = query.eq("sent_by", actor.user.id);
      const { data, error } = await query.order("created_at", { ascending: false }).limit(100);
      if (error) throw error;
      return json({ history: data || [] });
    }
    if (action === "send_link") {
      const recipientName = String(body.recipientName || "").trim();
      const recipientEmail = String(body.recipientEmail || "").trim().toLowerCase();
      const accountTypes = Array.isArray(body.accountTypes) ? [...new Set(body.accountTypes.map((v: any) => String(v)))] : [];
      if (recipientName.length < 2 || recipientName.length > 160 || !validEmail(recipientEmail) || recipientEmail.length > 254) return json({ error: "Enter a valid recipient name and email address." }, 400);
      if (!accountTypes.length || accountTypes.some((v: string) => !["REAL_ESTATE_TRUST","COMMISSION_TRUST"].includes(v))) return json({ error: "Select a valid trust account type." }, 400);
      if (!isAdmin && (actor.role !== "AGENT" || accountTypes.some((v: string) => v !== "REAL_ESTATE_TRUST"))) return json({ error: "Agents may send Real Estate Trust instructions only." }, 403);
      const { data: configured, error: configuredError } = await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,transit_number,account_name").in("account_type", accountTypes);
      if (configuredError) throw configuredError;
      if ((configured || []).length !== accountTypes.length) return json({ error: "The selected trust account information has not been configured by an administrator." }, 409);
      const token = randomHex(32), tokenHash = await sha256(token);
      const now = new Date(), expires = new Date(now.getTime() + 24 * 60 * 60 * 1000);
      const { data: created, error: createError } = await admin.from("dv_accounting_trust_info_email_log").insert({
        recipient_name: recipientName, recipient_email: recipientEmail, account_types: accountTypes,
        sent_by: actor.user.id, sent_by_email: actor.user.email || null,
        status: "PENDING", token_hash: tokenHash, otp_hash: null, otp_expires_at: null,
        link_expires_at: expires.toISOString(), otp_attempts: 0,
      }).select("id").single();
      if (createError) throw createError;
      const link = publicAppUrl.replace(/\/$/,"") + "/trust-account-information?token=" + token;
      const subject = "Secure Dream Valley Realty trust account instructions";
      const linkHtml = "<div style=\"font-family:Arial,sans-serif;max-width:620px;color:#172b4d\"><h2>Trust account instructions</h2><p>Hello " + htmlEscape(recipientName) + ",</p><p>" + htmlEscape(actor.user.email || "A Dream Valley Realty team member") + " has shared secure banking instructions with you.</p><p><a href=\"" + link + "\" style=\"display:inline-block;background:#0f2141;color:#fff;padding:12px 18px;text-decoration:none;border-radius:6px\">View secure instructions</a></p><p>The link expires in 24 hours. Open it and request a separate six-digit code sent to this same email address.</p><p>For security, banking numbers are not included in this email.</p></div>";
      try {
        const linkMessageId = await sendZoho(admin, recipientEmail, subject, linkHtml);
        const { error: updateError } = await admin.from("dv_accounting_trust_info_email_log").update({
          status: "SENT", sent_at: new Date().toISOString(),
          provider_message_id: JSON.stringify({ secure_link: linkMessageId }),
        }).eq("id", created.id);
        if (updateError) throw updateError;
        return json({ ok: true, logId: created.id, status: "SENT", message: "Secure link sent. The recipient requests a one-time verification code after opening it." });
      } catch (error) {
        const message = String((error as Error)?.message || "Email sending failed").slice(0, 350);
        await admin.from("dv_accounting_trust_info_email_log").update({ status: "FAILED", error_message: message, otp_hash: null }).eq("id", created.id);
        return json({ error: message, logId: created.id }, 502);
      }
    }
    return json({ error: "Unsupported action." }, 400);
  } catch (error) {
    const message = String((error as Error)?.message || "Request failed.").slice(0, 500);
    const status = /Only an administrator|Agents may|Only a.*administrator/i.test(message) ? 403 : /Sign in|session/i.test(message) ? 401 : 400;
    return json({ error: message }, status);
  }
});
