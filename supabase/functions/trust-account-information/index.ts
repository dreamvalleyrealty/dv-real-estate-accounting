import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";

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
  const logoImage = await document.embedPng(Uint8Array.from(atob("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[...snip...]"), (c) => c.charCodeAt(0)));
  page.drawImage(logoImage, { x: 38, y: 684, width: 60, height: 67.25 });
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(15 / 255, 33 / 255, 65 / 255);
  const gold = rgb(158 / 255, 133 / 255, 86 / 255);
  const center = (text: string, y: number, size = 10, font = regular, color = rgb(0, 0, 0)) => {
    page.drawText(text, { x: (612 - font.widthOfTextAtSize(text, size)) / 2, y, size, font, color });
  };
  center("TRUST ACCOUNT INFORMATION", 744, 16, bold, navy);
  center("(DEPOSIT ONLY)", 725, 10, bold, gold);
  center("885 Progress Ave #109", 697);
  center("Toronto. ON M1H 3G3", 682);
  const rows: [string, string][] = [
    ["Beneficiary Name:", "Dream Valley Realty Inc."],
    ["Bank Name:", "TD Canada Trust"],
    ["Bank Address:", "1900 Ellesmere Road, Scarborough, ON M1H 2V6"],
    ["Account Number:", "5278905"],
    ["Transit Number:", "17902"],
    ["Branch Number:", "004"],
    ["Swift Code:", "TDOMCATTTOR"],
  ];
  let y = 635;
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
      const token=randomHex(32),tokenHash=await sha256(token),now=new Date(),expires=new Date(now.getTime()+24*60*60*1000);
      const {data:created,error:createError}=await admin.from("dv_accounting_deposit_instruction_email_log").insert({
        listing_id:listing.id,property_address:propertyAddress,recipient_name:recipientName,recipient_email:recipientEmail,
        sent_by:actor.user.id,sent_by_email:actor.user.email||null,status:"PENDING",token_hash:tokenHash,
        link_expires_at:expires.toISOString(),otp_attempts:0
      }).select("id").single();
      if(createError)throw createError;
      const html="<div style=\"font-family:Arial,sans-serif;max-width:620px;color:#172b4d\"><h2>Real Estate Trust deposit instructions</h2><p>Hello "+htmlEscape(recipientName)+",</p><p>Please find attached Dream Valley Realty's Real Estate Trust deposit instructions for the following property:</p><p><strong>"+htmlEscape(propertyAddress)+"</strong></p><p>Please forward the deposit receipt to <a href=\"mailto:frontdesk@dvrealty.ca\">frontdesk@dvrealty.ca</a> once the transfer has been arranged.</p><p>Regards,<br/>Dream Valley Realty Inc.</p></div>";
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
