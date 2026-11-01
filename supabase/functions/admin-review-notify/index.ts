import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(v:unknown,s=200)=>new Response(JSON.stringify(v),{status:s,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const esc=(v:unknown)=>String(v??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]!));
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const auth=req.headers.get("Authorization")||"";
 if(!auth.startsWith("Bearer "))return json({error:"Sign in required."},401);
 const url=Deno.env.get("SUPABASE_URL")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 if(!url||!key)return json({error:"Notification service is not configured."},503);
 const db=createClient(url,key,{auth:{persistSession:false}});
 const {data:ud,error:ue}=await db.auth.getUser(auth.slice(7));
 if(ue||!ud.user)return json({error:"Session could not be verified."},401);
 let body:any;try{body=await req.json()}catch{return json({error:"Invalid request."},400)}
 const type=String(body.type||"").toUpperCase(),id=String(body.submissionId||"");
 if(!["LISTING","TRADE"].includes(type)||!id)return json({error:"Submission type and ID are required."},400);
 const table=type==="LISTING"?"dv_accounting_listing_submissions":"dv_accounting_agent_trade_submissions";
 const {data:row,error:re}=await db.from(table).select("*").eq("id",id).maybeSingle();
 if(re||!row)return json({error:"Submission not found."},404);
 if(String(row.status||"").toUpperCase()!=="SUBMITTED")return json({error:"Submission is not awaiting review."},409);
 const {data:caller}=await db.from("dv_accounting_user_profiles").select("role,active").eq("user_id",ud.user.id).maybeSingle();
 const isAdmin=!!caller?.active&&["ADMIN","SUPERADMIN"].includes(String(caller.role||"").toUpperCase());
 if(!isAdmin&&String(row.agent_id)!==String(ud.user.id) && String(row.submitted_by)!==String(ud.user.id) && String(row.created_by)!==String(ud.user.id))return json({error:"You are not allowed to notify for this submission."},403);
 const companyId=row.company_id||(await db.from("dv_accounting_agents").select("company_id").eq("id",row.agent_id).maybeSingle()).data?.company_id;
 if(!companyId)return json({error:"Brokerage company could not be identified."},400);
 const {data:recipients,error:pe}=await db.from("dv_accounting_review_notification_recipients").select("*").eq("company_id",companyId);
 if(pe)return json({error:"Could not load notification recipients."},500);
 const selected=(recipients||[]).filter((r:any)=>type==="LISTING"?(r.listing_email||r.listing_sms):(r.trade_email||r.trade_sms));
 if(!selected.length)return json({ok:true,sent:0,message:"No recipients are enabled for this notification."});
 const selectedUserIds=selected.map((r:any)=>r.user_id);
 const {data:profiles}=await db.from("dv_accounting_user_profiles").select("user_id,display_name,email,phone,active").in("user_id",selectedUserIds);
 const {data:employees}=await db.from("dv_accounting_employees").select("user_id,phone").in("user_id",selectedUserIds);
 const employeePhoneMap=new Map((employees||[]).map((e:any)=>[e.user_id,e.phone]));
 const profileMap=new Map((profiles||[]).map((p:any)=>[p.user_id,{...p,phone:p.phone||employeePhoneMap.get(p.user_id)||""}]));
 const {data:agent}=await db.from("dv_accounting_agents").select("*").eq("id",row.agent_id).maybeSingle();
 const agentName=agent?[agent.first_name,agent.last_name].filter(Boolean).join(" ")||agent.full_name||agent.name:"Agent";
 const address=type==="LISTING"?[row.property_address,row.unit_number,row.city,row.province,row.postal_code].filter(Boolean).join(", "):String(row.payload?.property_address||row.payload?.address||"Trade submission");
 const details=type==="LISTING"?("Property: "+address):("Property / transaction: "+address+"; Trade: "+String(row.trade_number||row.id));
 const submitted=String(row.submitted_at||row.updated_at||row.created_at||"");
 const eventKey=submitted||String(row.updated_at||row.id);
 const appUrl="https://bo.dvrealty.ca";
 const reviewUrl=appUrl+(type==="LISTING"?"/?page=listings&submission="+encodeURIComponent(id):"/?page=agent-trades&submission="+encodeURIComponent(id));
 const templateKey=type+"_SUBMITTED";
 const {data:template}=await db.from("dv_accounting_review_notification_templates").select("*").eq("company_id",companyId).eq("event_key",templateKey).maybeSingle();
 const templateVars:Record<string,string>={agent_name:agentName,document_name:type==="LISTING"?"Listing submission":"Trade submission",property_address:address,review_note:"",submission_type:type.toLowerCase(),app_url:reviewUrl};
 const renderTemplate=(value:string)=>String(value||"").replace(/\{\{\s*([a-z_]+)\s*\}\}/gi,(_m,k)=>templateVars[String(k).toLowerCase()]??"");
 let zoho:any=null,from="submissions@dvrealty.ca";
 async function getZoho(){
  if(zoho)return zoho;
  const cid=Deno.env.get("ZOHO_CLIENT_ID"),secret=Deno.env.get("ZOHO_CLIENT_SECRET");
  if(!cid||!secret)throw new Error("Zoho credentials are not configured.");
  const {data:integration}=await db.from("dv_accounting_private_integrations").select("secret_payload").eq("integration_key","zoho_mail").maybeSingle();
  const p=integration?.secret_payload;if(!p?.refresh_token)throw new Error("Zoho Mail is not connected.");
  const base=String(p.accounts_server||"https://accounts.zoho.com"),mail=String(p.mail_api_base||"https://mail.zoho.com");from="submissions@dvrealty.ca";
  const rr=await fetch(base+"/oauth/v2/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({refresh_token:p.refresh_token,client_id:cid,client_secret:secret,grant_type:"refresh_token"})});
  const token=await rr.json();if(!rr.ok||!token.access_token)throw new Error("Zoho token refresh failed.");
  const headers={Authorization:"Zoho-oauthtoken "+token.access_token,Accept:"application/json"};
  const ar=await fetch(mail+"/api/accounts",{headers});const aj=await ar.json();if(!ar.ok)throw new Error("Could not access Zoho accounts.");
  const list=Array.isArray(aj?.data)?aj.data:[aj?.data].filter(Boolean);
  const acct=list.find((a:any)=>String(a.accountAddress||a.emailAddress||a.primaryEmailAddress||a.email||"").toLowerCase()==="admin@dvrealty.ca")||list[0];
  if(!acct?.accountId)throw new Error("Zoho sender account could not be found.");
  zoho={mail,headers,accountId:String(acct.accountId)};return zoho;
 }
 const outcomes=[];
 for(const pref of selected){
  const p:any=profileMap.get(pref.user_id);if(!p?.active)continue;
  const channels=[...(type==="LISTING"?(pref.listing_email&&template?.email_enabled!==false?["EMAIL"]:[]):(pref.trade_email&&template?.email_enabled!==false?["EMAIL"]:[])),...(type==="LISTING"?(pref.listing_sms&&template?.sms_enabled!==false?["SMS"]:[]):(pref.trade_sms&&template?.sms_enabled!==false?["SMS"]:[]))];
  for(const channel of channels){
   const recipient=channel==="EMAIL"?String(p.email||"").trim():String(p.phone||"").trim();
   if(!recipient){outcomes.push({userId:p.user_id,channel,status:"SKIPPED",reason:"No email/phone on profile"});continue;}
   const logBase={company_id:companyId,submission_type:type,submission_id:id,event_key:eventKey,recipient_user_id:p.user_id,channel,recipient};
   const {data:log,error:le}=await db.from("dv_accounting_review_notification_log").insert(logBase).select("id").maybeSingle();
   if(le){outcomes.push({userId:p.user_id,channel,status:"DUPLICATE_OR_LOG_ERROR"});continue;}
   try{
    let providerId=null;
    if(channel==="EMAIL"){
     const z=await getZoho();
     const subject=renderTemplate(template?.email_subject||(type==="LISTING"?"Listing submitted for admin review — {{property_address}}":"Trade submitted for admin review — {{agent_name}}"));
     const emailBody=renderTemplate(template?.email_body||"New {{document_name}} from {{agent_name}}. {{property_address}}. Review: {{app_url}}");
     const html="<div style='font-family:Arial,sans-serif;white-space:pre-wrap'>"+esc(emailBody).replace(/(https:\/\/[^\s<]+)/g,'<a href="$1">$1</a>').replace(/\r?\n/g,"<br>")+"</div>";
     const sr=await fetch(z.mail+"/api/accounts/"+encodeURIComponent(z.accountId)+"/messages",{method:"POST",headers:{...z.headers,"Content-Type":"application/json"},body:JSON.stringify({fromAddress:from,toAddress:recipient,subject,content:html,mailFormat:"html"})});
     const sj=await sr.json().catch(()=>({}));if(!sr.ok||(sj?.status?.code&&Number(sj.status.code)>=400))throw new Error("Zoho rejected email (HTTP "+sr.status+").");
     providerId=sj?.data?.messageId||sj?.data?.message_id||null;
    }else{
     const sid=Deno.env.get("TWILIO_ACCOUNT_SID"),token=Deno.env.get("TWILIO_AUTH_TOKEN"),fromNumber=Deno.env.get("TWILIO_FROM_NUMBER");
     if(!sid||!token||!fromNumber)throw new Error("Twilio is not configured.");
     let sms=renderTemplate(template?.sms_body||"Dream Valley Realty: {{document_name}} submitted by {{agent_name}}. {{property_address}}.");if(!sms.includes(reviewUrl))sms=[sms.trim(),"Review: "+reviewUrl].filter(Boolean).join(" ");
     const sr=await fetch("https://api.twilio.com/2010-04-01/Accounts/"+sid+"/Messages.json",{method:"POST",headers:{Authorization:"Basic "+btoa(sid+":"+token),"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({To:recipient,From:fromNumber,Body:sms})});
     const sj=await sr.json().catch(()=>({}));if(!sr.ok)throw new Error("Twilio rejected SMS (HTTP "+sr.status+"): "+String(sj.message||"").slice(0,180));providerId=sj.sid||null;
    }
    await db.from("dv_accounting_review_notification_log").update({status:"SENT",provider_id:providerId,sent_at:new Date().toISOString()}).eq("id",log.id);
    outcomes.push({userId:p.user_id,channel,status:"SENT"});
   }catch(e){const msg=String((e as Error)?.message||"Notification failed").slice(0,350);await db.from("dv_accounting_review_notification_log").update({status:"FAILED",error_message:msg}).eq("id",log.id);outcomes.push({userId:p.user_id,channel,status:"FAILED",reason:msg});}
  }
 }
 return json({ok:true,outcomes});
});