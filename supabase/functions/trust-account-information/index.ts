import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb, degrees } from "https://esm.sh/pdf-lib@1.17.1";

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
async function buildTrustAccountPdf() {
  const document = await PDFDocument.create();
  const page = document.addPage([612, 792]);
  const logoBytes = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAGAAAABtCAYAAABeBmTmAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAABCZpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMC1jMDYwIDYxLjEzNDc3NywgMjAxMC8wMi8xMi0xNzozMjowMCAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wTU09Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9tbS8iIHhtbG5zOnN0UmVmPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvc1R5cGUvUmVzb3VyY2VSZWYjIiB4bWxuczp4bXA9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC8iIHhtbG5zOmRjPSJodHRwOi8vcHVybC5vcmcvZGMvZWxlbWVudHMvMS4xLyIgeG1wTU06T3JpZ2luYWxEb2N1bWVudElEPSJ1dWlkOjJiY2FhNTJlLTZkMTQtNGY2NC1hZGYxLWNjNGJiYjNhY2Q4MSIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDo5NTFGRERGMzAwRDcxMUVFOTE5NTk4Qzk5MDYzQ0U1RCIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDo5NTFGRERGMjAwRDcxMUVFOTE5NTk4Qzk5MDYzQ0U1RCIgeG1wOkNyZWF0b3JUb29sPSJBZG9iZSBQaG90b3Nob3AgQ1M1IFdpbmRvd3MiPiA8eG1wTU06RGVyaXZlZEZyb20gc3RSZWY6aW5zdGFuY2VJRD0ieG1wLmlpZDpBQzFCNUY2RDk5RkVFRDExOTIxQUUxRjE2RjRBQTQxMSIgc3RSZWY6ZG9jdW1lbnRJRD0iYWRvYmU6ZG9jaWQ6cGhv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"), (char) => char.charCodeAt(0));
  const logoImage = await document.embedPng(logoBytes);
  const logoWidth = 42;
  const logoHeight = logoWidth * logoImage.height / logoImage.width;
  page.drawImage(logoImage, { x: (612 - logoWidth) / 2, y: 744, width: logoWidth, height: logoHeight });
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(15 / 255, 33 / 255, 65 / 255);
  const gold = rgb(158 / 255, 133 / 255, 86 / 255);
  const center = (text: string, y: number, size = 10, font = regular, color = rgb(0, 0, 0)) => {
    page.drawText(text, { x: (612 - font.widthOfTextAtSize(text, size)) / 2, y, size, font, color });
  };
  center("TRUST ACCOUNT INFORMATION", 710, 16, bold, navy);
  center("(DEPOSIT ONLY)", 691, 10, bold, gold);
  center("885 Progress Ave #109", 663);
  center("Toronto. ON M1H 3G3", 648);
  const rows: [string, string][] = [
    ["Beneficiary Name:", "Dream Valley Realty Inc."],
    ["Bank Name:", "TD Canada Trust"],
    ["Bank Address:", "1900 Ellesmere Road, Scarborough, ON M1H 2V6"],
    ["Account Number:", "5278905"],
    ["Transit Number:", "17902"],
    ["Branch Number:", "004"],
    ["Swift Code:", "TDOMCATTTOR"],
  ];
  let y = 615;
  for (const [label, value] of rows) {
    page.drawText(label, { x: 92, y, size: 10.5, font: bold });
    page.drawText(value, { x: 205, y, size: 10.5, font: regular });
    y -= 25;
  }
  center("Once you have arranged the transfer please forward a receipt to", 428, 10, regular);
  center("frontdesk@dvrealty.ca we can send you a receipt for the deposit.", 412, 10, bold);
  page.drawText("NOTE: Please add an additional bank charge of $17.50 on top of the funds when doing wire", {
    x: 72, y: 378, size: 9, font: regular, maxWidth: 468,
  });
  page.drawText("transfers, if this fee is not received the deposit will be adjusted accordingly.", {
    x: 72, y: 363, size: 9, font: regular,
  });
  page.drawText("Wire transfer must come from the Canadian banks only", { x: 72, y: 340, size: 9, font: regular });
  center("*WE DO NOT ACCEPT INTERNATIONAL WIRE TRANSFERS*", 300, 10, bold, rgb(0.65, 0.12, 0.12));
  center("*WE DO NOT ACCEPT CASH DEPOSITS*", 282, 10, bold, rgb(0.65, 0.12, 0.12));
  page.drawLine({ start: { x: 72, y: 95 }, end: { x: 540, y: 95 }, thickness: 0.6, color: gold });
  center("885 Progress Ave. Suite #109, Toronto, ON M1H 3G3 | Tel 416-951-9929 | Fax 647-949-2959", 78, 7.5);
  center("The Brokerage is Independently Owned and Operated", 62, 7.5);
  return await document.save();
}
async function sendZohoWithPdfAttachment(admin: any, to: string, subject: string, body: string) {
  const z = await getZohoSecrets(admin);
  const fileName = "DREAM VALLEY - TRUST ACCOUNT INFORMATION.pdf";
  const pdfBytes = await buildTrustAccountPdf();
  // Zoho's raw upload endpoint is returning HTTP 415 for this PDF.
  // Use the documented multipart upload flow and let fetch set the boundary.
  const form = new FormData();
  form.append("attach", new Blob([pdfBytes], { type: "application/pdf" }), fileName);
  const uploadResponse = await fetch(
    z.mailBase + "/api/accounts/" + encodeURIComponent(z.accountId) + "/messages/attachments?uploadType=multipart&isInline=false",
    { method: "POST", headers: z.headers, body: form },
  );
  const uploadResult = await uploadResponse.json().catch(() => ({}));
  const attachment = Array.isArray(uploadResult?.data) ? uploadResult.data[0] : uploadResult?.data;
  if (!uploadResponse.ok || (uploadResult?.status?.code && Number(uploadResult.status.code) >= 400)
      || !attachment?.storeName || !attachment?.attachmentPath || !attachment?.attachmentName) {
    const detail = String(uploadResult?.status?.description || uploadResult?.message || uploadResult?.error || "Zoho did not return the required attachment details").slice(0, 220);
    console.error("Zoho PDF attachment upload failed", { httpStatus: uploadResponse.status, zohoStatus: uploadResult?.status?.code, detail });
    throw new Error("Zoho PDF attachment upload failed (HTTP " + uploadResponse.status + ", Zoho " + String(uploadResult?.status?.code || "unknown") + "): " + detail);
  }
  const response = await fetch(z.mailBase + "/api/accounts/" + encodeURIComponent(z.accountId) + "/messages", {
    method: "POST",
    headers: { ...z.headers, "Content-Type": "application/json" },
    body: JSON.stringify({
      fromAddress: z.from, toAddress: to, subject, content: body, mailFormat: "html",
      attachments: [{ storeName: attachment.storeName, attachmentPath: attachment.attachmentPath, attachmentName: attachment.attachmentName }],
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || (result?.status?.code && Number(result.status.code) >= 400)) {
    const detail = String(result?.status?.description || result?.message || result?.error || "Zoho rejected the message").slice(0, 220);
    console.error("Zoho deposit-instructions email failed", { httpStatus: response.status, zohoStatus: result?.status?.code, detail });
    throw new Error("Zoho email send failed (HTTP " + response.status + ", Zoho " + String(result?.status?.code || "unknown") + "): " + detail);
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
  const roleCandidate = (profileRole || metadataRole || "STAFF").replace(/[^A-Z]/g, "");
  const isSuperAdmin = roleCandidate === "SUPERADMIN" || roleCandidate === "SUPERADMINISTRATOR";
  const isAdmin = isSuperAdmin || ["ADMIN","ADMINISTRATOR","BROKER","BROKEROFRECORD","OFFICEADMIN","TRADEADMIN"].includes(roleCandidate);
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
  const role = isAdmin ? (isSuperAdmin ? "SUPERADMIN" : "ADMIN") : isLinkedAgent ? "AGENT" : roleCandidate === "AGENT" ? "STAFF" : roleCandidate;
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
  if (!supabaseUrl || !anonKey || !serviceKey || !encryptionSecret || encryptionSecret.length < 32 || !publicAppUrl) {
    return json({ error: "Secure trust account service is not fully configured. Set TRUST_ACCOUNT_ENCRYPTION_KEY (at least 32 characters) and TRUST_ACCOUNT_PUBLIC_URL." }, 503);
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
          await admin.from("dv_accounting_trust_info_email_log").update({ otp_hash: null, otp_expires_at: null, otp_sent_at: null }).eq("id", log.id);
          throw sendError;
        }
      }
      if (!log.token_verified) return json({ error: "Verify your email code before viewing the banking instructions." }, 403);
      if (new Date(log.link_expires_at).getTime() <= Date.now()) return json({ error: "This secure link has expired." }, 410);
      if (log.opened_at) return json({ error: "These banking instructions have already been viewed. Request a new secure link if you need access again." }, 410);
      const { data: instructions, error: instructionError } = await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,institution_number,transit_number,account_number_ciphertext,account_name,bank_address")
        .in("account_type", log.account_types);
      if (instructionError || !instructions?.length) return json({ error: "Banking instructions are not available." }, 503);
      const result: any[] = [];
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
        result.push({ account_type: item.account_type, institution: item.institution, institution_number: item.institution_number, transit_number: item.transit_number, account_number: accountNumber, account_name: item.account_name, bank_address: item.bank_address });
      }
      // Claim the one-time view atomically so two concurrent requests cannot both release the details.
      const { data: claimed, error: claimError } = await admin.from("dv_accounting_trust_info_email_log")
        .update({ status: "VIEWED", opened_at: new Date().toISOString() })
        .eq("id", log.id).is("opened_at", null).eq("token_verified", true).select("id").maybeSingle();
      if (claimError || !claimed) return json({ error: "These banking instructions have already been viewed. Request a new secure link if you need access again." }, 409);
      return json({ accounts: result });
    }


    if (["request_deposit_otp","verify_deposit_otp","view_deposit_instructions"].includes(action)) {
      const token=String(body.token||"");
      if(!/^[a-f0-9]{64}$/i.test(token))return json({error:"This secure link is invalid or expired."},400);
      const tokenHash=await sha256(token);
      const {data:log,error:logError}=await admin.from("dv_accounting_deposit_instruction_email_log").select("*").eq("token_hash",tokenHash).maybeSingle();
      const expectedStatus=action==="view_deposit_instructions"?"VERIFIED":"SENT";
      if(logError||!log||log.status!==expectedStatus||new Date(log.link_expires_at).getTime()<=Date.now())return json({error:"This secure link is invalid or expired."},410);
      if(action==="verify_deposit_otp"){
        const otp=String(body.otp||"").trim();
        if(!/^\d{6}$/.test(otp))return json({error:"Enter the six-digit code."},400);
        if(!log.otp_hash||!log.otp_expires_at||new Date(log.otp_expires_at).getTime()<=Date.now())return json({error:"The code has expired. Ask the sender to issue a new secure link."},410);
        if (log.token_verified) return json({error:"This secure link has already been verified."},409);
        if(Number(log.otp_attempts||0)>=5)return json({error:"Too many attempts. Ask the sender to issue a new secure link."},429);
        if(await sha256(token+":"+otp)!==log.otp_hash){await admin.from("dv_accounting_deposit_instruction_email_log").update({otp_attempts:Number(log.otp_attempts||0)+1}).eq("id",log.id);return json({error:"The code does not match. Check the email and try again."},401)}
        await admin.from("dv_accounting_deposit_instruction_email_log").update({status:"VERIFIED",token_verified:true,verified_at:new Date().toISOString()}).eq("id",log.id);
        return json({ok:true,verified:true});
      }
      if(action==="request_deposit_otp"){
        if(log.token_verified)return json({error:"This secure link has already been verified."},409);
        if(log.otp_sent_at&&Date.now()-new Date(log.otp_sent_at).getTime()<60_000)return json({error:"Please wait one minute before requesting another code."},429);
        const otp=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,"0");
        const otpHtml="<div style=\"font-family:Arial,sans-serif;max-width:620px;color:#172b4d\"><h2>Your verification code</h2><p>Hello "+htmlEscape(log.recipient_name)+",</p><p>Your one-time code is:</p><p style=\"font-size:30px;font-weight:bold;letter-spacing:6px\">"+otp+"</p><p>This code expires in 15 minutes. Do not share it with anyone.</p></div>";
        const {error:updateError}=await admin.from("dv_accounting_deposit_instruction_email_log").update({otp_hash:await sha256(token+":"+otp),otp_expires_at:new Date(Date.now()+15*60*1000).toISOString(),otp_sent_at:new Date().toISOString(),otp_attempts:0}).eq("id",log.id);
        if(updateError)throw updateError;
        try{await sendZoho(admin,log.recipient_email,"Your Dream Valley Realty verification code",otpHtml);return json({ok:true,message:"A verification code has been sent to the email address this link was issued to."})}
        catch(sendError){await admin.from("dv_accounting_deposit_instruction_email_log").update({otp_hash:null,otp_expires_at:null,otp_sent_at:null}).eq("id",log.id);throw sendError}
      }
      if(!log.token_verified)return json({error:"Verify your email code before viewing deposit instructions."},403);
      if(log.opened_at)return json({error:"These deposit instructions have already been viewed. Request a new secure link if you need access again."},410);
      const {data:instructions,error:instructionError}=await admin.from("dv_accounting_trust_account_instructions").select("account_type,institution,institution_number,transit_number,account_number_ciphertext,account_name,bank_address").eq("account_type","REAL_ESTATE_TRUST").maybeSingle();
      if(instructionError||!instructions)return json({error:"Real Estate Trust deposit instructions are not available."},503);
      let encrypted:Uint8Array,accountNumber:string;
      try{
        const raw=instructions.account_number_ciphertext;
        if(raw instanceof Uint8Array)encrypted=raw;
        else if(Array.isArray(raw))encrypted=new Uint8Array(raw);
        else{const encoded=String(raw||"");const hex=encoded.startsWith("\\x")?encoded.slice(2):encoded;if(!/^[0-9a-f]+$/i.test(hex)||hex.length%2!==0)throw new Error("Invalid encrypted account data.");encrypted=new Uint8Array(hex.length/2);for(let i=0;i<encrypted.length;i++)encrypted[i]=Number.parseInt(hex.slice(i*2,i*2+2),16)}
        accountNumber=await decrypt(encrypted,encryptionSecret);
      }catch{return json({error:"Banking instructions could not be decrypted."},500)}
      const {data:claimed,error:claimError}=await admin.from("dv_accounting_deposit_instruction_email_log").update({status:"VIEWED",opened_at:new Date().toISOString()}).eq("id",log.id).is("opened_at",null).eq("token_verified",true).select("id").maybeSingle();
      if(claimError||!claimed)return json({error:"These deposit instructions have already been viewed. Request a new secure link if you need access again."},409);
      return json({property_address:log.property_address,instructions:{institution:instructions.institution,institution_number:instructions.institution_number,transit_number:instructions.transit_number,account_number:accountNumber,account_name:instructions.account_name,bank_address:instructions.bank_address}});
    }

    if (action === "upload_deposit_receipts") {
      const token=String(body.token||"");
      if(!/^[a-f0-9]{64}$/i.test(token))return json({error:"This upload link is invalid or expired."},400);
      const tokenHash=await sha256(token);
      const {data:log,error:logError}=await admin.from("dv_accounting_deposit_instruction_email_log").select("id,listing_id,property_address,recipient_email,status,link_expires_at").eq("token_hash",tokenHash).maybeSingle();
      if(logError||!log||!["SENT","VERIFIED","VIEWED"].includes(log.status)||new Date(log.link_expires_at).getTime()<=Date.now())return json({error:"This upload link is invalid or has expired."},410);
      const files=Array.isArray(body.files)?body.files:[];
      if(!files.length||files.length>10)return json({error:"Choose between 1 and 10 files per upload."},400);
      const allowed=new Set(["application/pdf","image/jpeg","image/png","image/webp"]);
      const saved=[];
      for(const item of files){
        const name=String(item?.name||"").replace(/[\\/]/g,"_").replace(/[^a-zA-Z0-9._ -]/g,"_").slice(0,160);
        const mime=String(item?.type||"").toLowerCase();
        const encoded=String(item?.data||"").replace(/^data:[^,]*;base64,/,"");
        if(!name||!allowed.has(mime)||!encoded||encoded.length>14_000_000)return json({error:"Only PDF, JPG, PNG and WEBP files up to 10 MB each are accepted."},400);
        const binary=atob(encoded),bytes=new Uint8Array(binary.length);
        for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
        if(bytes.length>10*1024*1024)return json({error:"Each file must be 10 MB or smaller."},400);
        const path="listing-deposit-receipts/"+log.listing_id+"/"+log.id+"/"+crypto.randomUUID()+"-"+name.replace(/\s+/g,"_");
        const {error:uploadError}=await admin.storage.from("dv-trade-documents").upload(path,bytes,{contentType:mime,upsert:false});
        if(uploadError)throw uploadError;
        const {data:record,error:recordError}=await admin.from("dv_accounting_deposit_receipt_uploads").insert({email_log_id:log.id,listing_id:log.listing_id,property_address:log.property_address,recipient_email:log.recipient_email,storage_path:path,file_name:name,mime_type:mime,file_size:bytes.length}).select("id,file_name,uploaded_at").single();
        if(recordError){await admin.storage.from("dv-trade-documents").remove([path]);throw recordError}
        saved.push(record);
      }
      return json({ok:true,uploaded:saved.length,files:saved,message:saved.length+" receipt file(s) uploaded successfully."});
    }
    const actor = await requireActor(req, admin, supabaseUrl, anonKey);
    const isAdmin = ["SUPERADMIN","ADMIN"].includes(actor.role);
    if (action === "get_settings") {
      if (!isAdmin) return json({ error: "Only an administrator can view the saved banking instructions." }, 403);
      const { data, error } = await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,institution_number,transit_number,account_name,bank_address,updated_at");
      if (error) throw error;
      // Return metadata only. The full account number is never sent back to the browser.
      const accounts: any = {};
      for (const row of data || []) accounts[row.account_type === "REAL_ESTATE_TRUST" ? "real_estate_trust" : "commission_trust"] = {
        institution: row.institution, institution_number: row.institution_number, transit_number: row.transit_number, account_name: row.account_name,
        bank_address: row.bank_address, account_number: "",
      };
      return json({ accounts });
    }
    if (action === "save_settings") {
      if (!isAdmin) return json({ error: "Only an administrator can update trust banking instructions." }, 403);
      const accounts = body.accounts || {};
      const updates: any[] = [];
      const metadataUpdates: any[] = [];
      const seenTypes: string[] = [];
      for (const [key, type] of [["real_estate_trust","REAL_ESTATE_TRUST"],["commission_trust","COMMISSION_TRUST"]] as const) {
        const row = accounts[key] || {};
        const institution = String(row.institution || "").trim();
        const institutionNumber = String(row.institution_number || "").trim();
        const transit = String(row.transit_number || "").trim();
        const accountName = String(row.account_name || "").trim();
        const accountNumber = String(row.account_number || "").trim();
        if (!institution || !institutionNumber || !transit || !accountName) return json({ error: "Complete the financial institution, institution number, transit number, and account name for both trust accounts." }, 400);
        seenTypes.push(type);
        if (!/^\d{3}$/.test(institutionNumber)) return json({ error: "Enter the three-digit Canadian institution number." }, 400);
        if (!/^\d{5}$/.test(transit)) return json({ error: "Enter a five-digit transit number." }, 400);
        if (accountNumber) {
          if (!/^\d{5,20}$/.test(accountNumber)) return json({ error: "Enter an account number containing 5–20 digits." }, 400);
          const cipher = await encrypt(accountNumber, encryptionSecret);
          updates.push({ account_type: type, institution, institution_number: institutionNumber, transit_number: transit, account_number_ciphertext: "\\x" + bytesToHex(cipher), account_name: accountName, bank_address: String(row.bank_address || "").trim() || null, updated_at: new Date().toISOString(), updated_by: actor.user.id });
        } else {
          metadataUpdates.push({ account_type: type, institution, institution_number: institutionNumber, transit_number: transit, account_name: accountName, bank_address: String(row.bank_address || "").trim() || null, updated_at: new Date().toISOString(), updated_by: actor.user.id });
        }
      }
      if (seenTypes.length !== 2) return json({ error: "Both trust account records must be provided." }, 400);
      if (metadataUpdates.length) {
        const typesNeedingExisting = metadataUpdates.map(item => item.account_type);
        const { data: existingRows, error: existingError } = await admin.from("dv_accounting_trust_account_instructions")
          .select("account_type").in("account_type", typesNeedingExisting);
        if (existingError) throw existingError;
        const existingSet = new Set((existingRows || []).map((item: any) => item.account_type));
        if (typesNeedingExisting.some(type => !existingSet.has(type))) return json({ error: "Enter the full account number the first time each trust account is configured." }, 400);
      }
      for (const update of metadataUpdates) {
        const { account_type, ...fields } = update;
        const { error } = await admin.from("dv_accounting_trust_account_instructions").update(fields).eq("account_type", account_type);
        if (error) throw error;
      }
      for (const update of updates) {
        const { error } = await admin.from("dv_accounting_trust_account_instructions").upsert(update, { onConflict: "account_type" });
        if (error) throw error;
      }
      return json({ ok: true, message: "Both trust account instructions were saved securely." });
    }

    if (action === "get_deposit_receipt_uploads") {
      const listingId=String(body.listingId||"");
      if(!/^[0-9a-f-]{36}$/i.test(listingId))return json({error:"Select a valid property."},400);
      const {data:listing,error:listingError}=await admin.from("dv_accounting_listing_submissions").select("id,agent_id,additional_agent_ids").eq("id",listingId).maybeSingle();
      if(listingError)throw listingError;if(!listing)return json({error:"Property not found."},404);
      if(!isAdmin){
        if(actor.role!=="AGENT")return json({error:"You do not have access to these receipts."},403);
        const {data:agent,error:agentError}=await admin.from("dv_accounting_agents").select("id,user_id,email,active").eq("user_id",actor.user.id).maybeSingle();
        if(agentError)throw agentError;
        if(!agent||agent.active===false||String(agent.email||"").toLowerCase()!==String(actor.user.email||"").toLowerCase()||(listing.agent_id!==agent.id&&!(Array.isArray(listing.additional_agent_ids)&&listing.additional_agent_ids.includes(agent.id))))return json({error:"You may view receipts only for listings assigned to you."},403);
      }
      const [{data:emails,error:emailError},{data:uploads,error:uploadError}]=await Promise.all([
        admin.from("dv_accounting_deposit_instruction_email_log").select("id,recipient_name,recipient_email,sent_by_email,status,created_at,sent_at,link_expires_at,error_message").eq("listing_id",listingId).order("created_at",{ascending:false}).limit(100),
        admin.from("dv_accounting_deposit_receipt_uploads").select("id,email_log_id,file_name,mime_type,file_size,uploaded_at,storage_path").eq("listing_id",listingId).order("uploaded_at",{ascending:false}).limit(200)
      ]);
      if(emailError)throw emailError;if(uploadError)throw uploadError;
      const files=[];
      for(const file of uploads||[]){const {data:link,error:linkError}=await admin.storage.from("dv-trade-documents").createSignedUrl(file.storage_path,900);files.push({...file,download_url:linkError?null:link?.signedUrl||null})}
      return json({emails:emails||[],uploads:files});
    }
    if (action === "get_deposit_instructions_history") {
let query = admin.from("dv_accounting_deposit_instruction_email_log")
        .select("id,listing_id,property_address,recipient_name,recipient_email,sent_by,sent_by_email,status,created_at,sent_at,link_expires_at,verified_at,opened_at,error_message")
        .order("created_at", {ascending:false}).limit(100);
      if (!isAdmin) query = query.eq("sent_by", actor.user.id);
      const { data: rows, error: historyError } = await query;
      if (historyError) throw historyError;
      return json({history:rows||[]});
    }
    if (action === "send_deposit_instructions") {
      const listingId=String(body.listingId||"").trim();
      const recipientName=String(body.recipientName||"").trim();
      const recipientEmail=String(body.recipientEmail||"").trim().toLowerCase();
      if(!/^[0-9a-f-]{36}$/i.test(listingId))return json({error:"Select a valid listing."},400);
      if(recipientName.length<2||recipientName.length>160||!validEmail(recipientEmail)||recipientEmail.length>254)return json({error:"Enter the buyer's agent name and a valid email address."},400);
      const {data:listing,error:listingError}=await admin.from("dv_accounting_listing_submissions")
        .select("id,agent_id,additional_agent_ids,property_address,unit_number,city,province,postal_code,mls_number,status")
        .eq("id",listingId).maybeSingle();
      if(listingError)throw listingError;
      if(!listing)return json({error:"The selected listing could not be found."},404);
      if (!isAdmin) {
        if (actor.role !== "AGENT") return json({error:"Only agents and administrators may send deposit instructions."},403);
        const {data:linkedAgent,error:agentLookupError}=await admin.from("dv_accounting_agents")
          .select("id,user_id,email,active").eq("user_id",actor.user.id).maybeSingle();
        if (agentLookupError) throw agentLookupError;
        const assigned = !!linkedAgent && linkedAgent.active !== false
          && String(linkedAgent.email||"").trim().toLowerCase() === String(actor.user.email||"").trim().toLowerCase()
          && (listing.agent_id===linkedAgent.id || (Array.isArray(listing.additional_agent_ids)&&listing.additional_agent_ids.includes(linkedAgent.id)));
        if (!assigned) return json({error:"You may send instructions only for listings assigned to you."},403);
      }
      const propertyAddress=[listing.property_address,listing.unit_number?"Unit "+listing.unit_number:"",listing.city,listing.province,listing.postal_code].filter(Boolean).join(", ");
      if(!propertyAddress.trim())return json({error:"The selected listing does not have a complete property address."},400);
      const {data:accountRows,error:accountError}=await admin.from("dv_accounting_trust_account_instructions")
        .select("account_type,institution,institution_number,transit_number,account_number_ciphertext,account_name,bank_address")
        .eq("account_type","REAL_ESTATE_TRUST").limit(1);
      if(accountError)throw accountError;
      if(!accountRows?.length)return json({error:"Real Estate Trust deposit instructions have not been configured by an administrator."},409);
      const token=randomHex(32),tokenHash=await sha256(token),now=new Date(),expires=new Date(now.getTime()+7*24*60*60*1000);
      const {data:created,error:createError}=await admin.from("dv_accounting_deposit_instruction_email_log").insert({
        listing_id:listing.id,property_address:propertyAddress,recipient_name:recipientName,recipient_email:recipientEmail,
        sent_by:actor.user.id,sent_by_email:actor.user.email||null,status:"PENDING",token_hash:tokenHash,
        link_expires_at:expires.toISOString(),otp_attempts:0
      }).select("id").single();
      if(createError)throw createError;
      const uploadUrl=publicAppUrl.replace(/\/+$/,"")+"/deposit-receipt-upload?token="+encodeURIComponent(token);
      const html="<div style=\"font-family:Arial,sans-serif;max-width:620px;color:#172b4d\"><h2>Real Estate Trust deposit instructions</h2><p>Hello "+htmlEscape(recipientName)+",</p><p>Please find attached Dream Valley Realty's Real Estate Trust deposit instructions for the following property:</p><p><strong>"+htmlEscape(propertyAddress)+"</strong></p><p>After arranging the deposit, use the secure link below to upload your deposit receipt or bank confirmation. You may upload multiple receipts for this property.</p><p><a href=\""+htmlEscape(uploadUrl)+"\" style=\"display:inline-block;background:#0f2141;color:#fff;padding:12px 18px;text-decoration:none;border-radius:5px\">Upload Deposit Receipt</a></p><p>This upload link expires in 7 days. You can upload multiple PDF or image files during that period.</p><p>Regards,<br/>Dream Valley Realty Inc.</p></div>";
      try{
        const messageId=await sendZohoWithPdfAttachment(admin,recipientEmail,"Real Estate Trust Deposit Instructions — "+propertyAddress,html);
        const {error:updateError}=await admin.from("dv_accounting_deposit_instruction_email_log").update({status:"SENT",sent_at:new Date().toISOString(),provider_message_id:JSON.stringify({pdf_attachment:messageId})}).eq("id",created.id);
        if(updateError)throw updateError;
        return json({ok:true,status:"SENT",logId:created.id,message:"Deposit instructions PDF attached and emailed to the buyer's agent."});
      }catch(error){
        const message=String((error as Error)?.message||"Email sending failed").slice(0,350);
        await admin.from("dv_accounting_deposit_instruction_email_log").update({status:"FAILED",error_message:message}).eq("id",created.id);
        return json({error:message,logId:created.id},502);
      }
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
