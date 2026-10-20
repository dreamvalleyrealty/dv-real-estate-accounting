import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"content-type, x-worker-token","Access-Control-Allow-Methods":"POST, OPTIONS"};
function json(body: unknown, status=200) { return new Response(JSON.stringify(body), {status, headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}}); }
const validEmail=(v:string)=>/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
function decodeBase64(input:string) { const raw=atob(input); const bytes=new Uint8Array(raw.length); for(let i=0;i<raw.length;i++) bytes[i]=raw.charCodeAt(i); return bytes; }

Deno.serve(async (req:Request) => {
  if(req.method==="OPTIONS") return new Response("ok",{headers:cors});
  if(req.method!=="POST") return json({error:"Method not allowed"},405);
  const supabaseUrl=Deno.env.get("SUPABASE_URL"), serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const clientId=Deno.env.get("ZOHO_CLIENT_ID"), clientSecret=Deno.env.get("ZOHO_CLIENT_SECRET");
  if(!supabaseUrl||!serviceKey||!clientId||!clientSecret) return json({error:"Scheduled Zoho service is not configured."},503);
  const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
  const provided=req.headers.get("x-worker-token")||"";
  const {data:authRow,error:authError}=await admin.from("dv_accounting_scheduled_email_worker_auth").select("worker_token").eq("id",true).maybeSingle();
  if(authError||!authRow?.worker_token||provided.length<32||provided!==authRow.worker_token) return json({error:"Unauthorized worker request."},401);

  const {data:due,error:dueError}=await admin.from("dv_accounting_scheduled_emails")
    .select("*").eq("status","SCHEDULED").lte("scheduled_at",new Date().toISOString()).order("scheduled_at",{ascending:true}).limit(5);
  if(dueError) return json({error:"Could not read scheduled emails."},500);
  const results=[];
  for(const job of due||[]) {
    const {data:claimed,error:claimError}=await admin.from("dv_accounting_scheduled_emails").update({status:"PROCESSING",attempts:Number(job.attempts||0)+1,updated_at:new Date().toISOString()}).eq("id",job.id).eq("status","SCHEDULED").select("*").maybeSingle();
    if(claimError||!claimed) continue;
    let logId:string|null=null;
    try {
      const recipient=String(claimed.recipient_email||"").trim(), cc=String(claimed.cc_email||"").trim();
      const subject=String(claimed.subject||"").trim(), html=String(claimed.html_body||"").trim();
      const attachmentName=String(claimed.attachment_name||"").trim(), base64=String(claimed.attachment_base64||"");
      const documentType=String(claimed.document_type||"");
      if(!validEmail(recipient)||(cc&&!validEmail(cc))) throw new Error("Scheduled email has an invalid recipient address.");
      if(!subject||subject.length>250||!html||html.length>40000) throw new Error("Scheduled email subject or body is missing or too long.");
      if(!["COMMISSION_INVOICE","SELLER_COMMISSION_STATEMENT"].includes(documentType)) throw new Error("Unsupported scheduled document type.");
      if(!/^[A-Za-z0-9._ -]{1,160}\.pdf$/i.test(attachmentName)||!base64||base64.length>12000000) throw new Error("Scheduled email PDF is missing or exceeds the allowed size.");
      const bytes=decodeBase64(base64);
      if(bytes.length<5||bytes[0]!==37||bytes[1]!==80||bytes[2]!==68||bytes[3]!==70||bytes.length>8*1024*1024) throw new Error("Scheduled attachment is not a valid PDF no larger than 8 MB.");
      const {data:integration,error:integrationError}=await admin.from("dv_accounting_private_integrations").select("secret_payload").eq("integration_key","zoho_mail").maybeSingle();
      if(integrationError||!integration?.secret_payload?.refresh_token) throw new Error("Zoho Mail is not connected. Reconnect the mailbox first.");
      const p=integration.secret_payload, accountsServer=String(p.accounts_server||"https://accounts.zoho.com"), mailBase=String(p.mail_api_base||"https://mail.zoho.com"), from=String(p.sender_email||"admin@dvrealty.ca");
      const refresh=await fetch(accountsServer+"/oauth/v2/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({refresh_token:p.refresh_token,client_id:clientId,client_secret:clientSecret,grant_type:"refresh_token"})});
      const token=await refresh.json().catch(()=>({}));
      if(!refresh.ok||!token.access_token) throw new Error("Zoho token refresh failed. Reconnect Zoho Mail and try again.");
      const headers={Authorization:"Zoho-oauthtoken "+token.access_token,Accept:"application/json"};
      const ar=await fetch(mailBase+"/api/accounts",{headers});
      const accountJson=await ar.json().catch(()=>({}));
      if(!ar.ok) throw new Error("Could not access Zoho Mail accounts (HTTP "+ar.status+").");
      const list=Array.isArray(accountJson?.data)?accountJson.data:Array.isArray(accountJson)?accountJson:(accountJson?.data&&typeof accountJson.data==="object"?[accountJson.data]:[]);
      const acct=list.find((a:any)=>String(a.accountAddress||a.emailAddress||a.primaryEmailAddress||a.email||"").toLowerCase()===from.toLowerCase())||list.find((a:any)=>String(a.accountName||"").toLowerCase().includes("admin"))||list[0];
      const accountId=acct?.accountId||acct?.account_id||acct?.id;
      if(!accountId) throw new Error("Zoho account ID could not be identified.");
      const {data:log,error:logError}=await admin.from("dv_accounting_email_log").insert({transaction_id:claimed.transaction_id||null,document_type:documentType,recipient_email:recipient,cc_email:cc||null,subject,attachment_name:attachmentName,status:"PENDING",sent_by:claimed.created_by||null,sent_by_email:claimed.created_by_email||null}).select("id").single();
      if(logError) throw new Error("Could not create the email audit record.");
      logId=log.id;
      const uploadUrl=new URL(mailBase+"/api/accounts/"+encodeURIComponent(String(accountId))+"/messages/attachments");
      uploadUrl.searchParams.set("fileName",attachmentName); uploadUrl.searchParams.set("isInline","false");
      const upload=await fetch(uploadUrl.toString(),{method:"POST",headers:{...headers,"Content-Type":"application/octet-stream"},body:bytes});
      const uploadJson=await upload.json().catch(()=>({})), uploaded=uploadJson?.data;
      if(!upload.ok||!uploaded?.storeName||!uploaded?.attachmentName||!uploaded?.attachmentPath) throw new Error("Zoho attachment upload failed (HTTP "+upload.status+").");
      const sendBody:any={fromAddress:from,toAddress:recipient,subject,content:html,mailFormat:"html",attachments:[{storeName:uploaded.storeName,attachmentName:uploaded.attachmentName,attachmentPath:uploaded.attachmentPath}]};
      if(cc) sendBody.ccAddress=cc;
      const sent=await fetch(mailBase+"/api/accounts/"+encodeURIComponent(String(accountId))+"/messages",{method:"POST",headers:{...headers,"Content-Type":"application/json"},body:JSON.stringify(sendBody)});
      const sentJson=await sent.json().catch(()=>({}));
      if(!sent.ok||(sentJson?.status?.code&&Number(sentJson.status.code)>=400)) throw new Error("Zoho rejected the email request (HTTP "+sent.status+").");
      const providerId=sentJson?.data?.messageId||sentJson?.data?.message_id||sentJson?.messageId||null;
      await admin.from("dv_accounting_email_log").update({status:"SENT",provider_message_id:providerId,provider_response:{status:sentJson?.status||null},sent_at:new Date().toISOString()}).eq("id",logId);
      await admin.from("dv_accounting_scheduled_emails").update({status:"SENT",sent_at:new Date().toISOString(),email_log_id:logId,error_message:null,updated_at:new Date().toISOString()}).eq("id",claimed.id);
      results.push({id:claimed.id,status:"SENT"});
    } catch(e) {
      const msg=String((e as Error)?.message||"Scheduled email failed").slice(0,400);
      if(logId) await admin.from("dv_accounting_email_log").update({status:"FAILED",error_message:msg}).eq("id",logId);
      await admin.from("dv_accounting_scheduled_emails").update({status:"FAILED",error_message:msg,updated_at:new Date().toISOString()}).eq("id",claimed.id);
      results.push({id:claimed.id,status:"FAILED",error:msg});
    }
  }
  return json({ok:true,processed:results.length,results});
});