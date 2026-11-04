import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const esc=(v:unknown)=>String(v??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]!));
const upper=(v:unknown)=>String(v??"").trim().toUpperCase();

Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const authorization=req.headers.get("Authorization")||"";
 if(!authorization.startsWith("Bearer "))return json({error:"Sign in required."},401);
 const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!serviceKey)return json({error:"Notification service is not configured."},503);
 const db=createClient(url,serviceKey,{auth:{persistSession:false}});
 const {data:authData,error:authError}=await db.auth.getUser(authorization.slice(7));
 if(authError||!authData.user)return json({error:"Session could not be verified."},401);
 const {data:caller}=await db.from("dv_accounting_user_profiles").select("role,active").eq("user_id",authData.user.id).maybeSingle();
 if(!caller?.active||!["ADMIN","SUPERADMIN","MANAGER"].includes(upper(caller.role)))return json({error:"Administrator access required."},403);
 let body:any;try{body=await req.json()}catch{return json({error:"Invalid request."},400)}
 const type=upper(body.type),submissionId=String(body.submissionId||"");
 if(!["LISTING","TRADE"].includes(type)||!submissionId)return json({error:"Choose a valid Listing or Trade submission."},400);
 const isListing=type==="LISTING";
 const submissionTable=isListing?"dv_accounting_listing_submissions":"dv_accounting_agent_trade_submissions";
 const docTable=isListing?"dv_accounting_listing_documents":"dv_accounting_agent_trade_documents";
 const fk=isListing?"listing_id":"submission_id";
 const statusCol=isListing?"review_status":"match_status";
 const noteCol=isListing?"review_notes":"match_notes";
 const {data:submission,error:submissionError}=await db.from(submissionTable).select("*").eq("id",submissionId).maybeSingle();
 if(submissionError||!submission)return json({error:"Submission not found."},404);
 const {data:docs,error:docsError}=await db.from(docTable).select("*").eq(fk,submissionId).order("created_at",{ascending:true});
 if(docsError)return json({error:"Could not load the submitted documents."},500);
 if(!docs?.length)return json({error:"There are no documents to review."},400);
 const snapshot=(docs||[]).map((d:any)=>({id:d.id,name:d.document_name||d.document_type||"Document",status:upper(d[statusCol]),note:String(d[noteCol]||"").trim(),storage_path:d.storage_path||""}));
 const approved=snapshot.filter((d:any)=>isListing?d.status==="APPROVED":["MATCH","APPROVED"].includes(d.status));
 const rejected=snapshot.filter((d:any)=>isListing?d.status==="NOT_APPROVED":["MISMATCH","REJECTED","NOT_APPROVED","NOT APPROVED"].includes(d.status));
 const pending=snapshot.length-approved.length-rejected.length;
 if(pending>0)return json({error:"Review every uploaded document before completing the review. "+pending+" document(s) are still pending."},400);
 if(rejected.some((d:any)=>!d.note))return json({error:"Add a correction note to every Not Approved document before notifying the agent."},400);
 const outcome=rejected.length===0?"ALL_APPROVED":approved.length===0?"ACTION_REQUIRED":"PARTIALLY_APPROVED";
 const {data:agent,error:agentError}=await db.from("dv_accounting_agents").select("*").eq("id",submission.agent_id).maybeSingle();
 if(agentError||!agent)return json({error:"Agent record not found."},404);
 const companyId=submission.company_id||agent.company_id;
 if(!companyId)return json({error:"Brokerage company could not be identified."},400);
 let profile:any=null;
 if(agent.user_id){const p=await db.from("dv_accounting_user_profiles").select("user_id,email,phone,display_name").eq("user_id",agent.user_id).maybeSingle();profile=p.data;}
 const recipientEmail=String(profile?.email||agent.email||"").trim();
 const recipientPhone=String(profile?.phone||agent.phone||agent.cell_phone||"").replace(/[\s().-]/g,"");
 const property=isListing?[submission.property_address,submission.unit_number,submission.city,submission.province].filter(Boolean).join(", "):String(submission.payload?.property_address||submission.payload?.address||submission.trade_number||"Trade submission");
 const agentName=String(profile?.display_name||agent.name||[agent.first_name,agent.last_name].filter(Boolean).join(" ")||"Agent");
 const {data:previous}=await db.from("dv_accounting_document_review_cycles").select("*").eq("submission_type",type).eq("submission_id",submissionId).order("cycle_number",{ascending:false}).limit(1).maybeSingle();
 let cycle=previous;
 const sameSnapshot=previous&&JSON.stringify(previous.document_snapshot)===JSON.stringify(snapshot);
 if(!sameSnapshot){
   const nextNumber=Number(previous?.cycle_number||0)+1;
   const inserted=await db.from("dv_accounting_document_review_cycles").insert({
     submission_type:type,submission_id:submissionId,cycle_number:nextNumber,outcome,
     document_snapshot:snapshot,total_documents:snapshot.length,approved_count:approved.length,
     not_approved_count:rejected.length,created_by:authData.user.id
   }).select("*").single();
   if(inserted.error){
     const raced=await db.from("dv_accounting_document_review_cycles").select("*").eq("submission_type",type).eq("submission_id",submissionId).eq("cycle_number",nextNumber).maybeSingle();
     if(!raced.data)return json({error:"Could not start the notification cycle: "+inserted.error.message},500);
     cycle=raced.data;
   }else cycle=inserted.data;
 }
 if(!cycle)return json({error:"Could not create a review cycle."},500);
 const vars={agent_name:agentName,document_type:type==="LISTING"?"Listing":"Trade",property_address:property,app_url:"https://bo.dvrealty.ca"};
 const lines=snapshot.map((d:any)=>"- "+d.name+": "+(d.status==="APPROVED"||d.status==="MATCH"?"APPROVED":"NOT APPROVED")+(d.note?" — "+d.note:""));
 const resultLabel=outcome==="ALL_APPROVED"?"ALL APPROVED":outcome==="ACTION_REQUIRED"?"ACTION REQUIRED":"PARTIALLY APPROVED";
 const subject=type+" review: "+resultLabel+" — "+property;
 const plain="Hello "+agentName+",\n\nThe document review for your "+type.toLowerCase()+" submission at "+property+" is complete.\n\nResult: "+resultLabel+"\nApproved: "+approved.length+" | Not approved: "+rejected.length+"\n\n"+lines.join("\n")+"\n\nPlease sign in to DV Back Office to review the results and upload any required corrections.\n\nDream Valley Realty";
 const html="<div style='font-family:Arial,sans-serif;line-height:1.5'><p>Hello "+esc(agentName)+",</p><p>The document review for your "+type.toLowerCase()+" submission at <b>"+esc(property)+"</b> is complete.</p><p><b>Result: "+esc(resultLabel)+"</b><br>Approved: "+approved.length+" | Not approved: "+rejected.length+"</p><ul>"+snapshot.map((d:any)=>"<li><b>"+esc(d.name)+": "+(d.status==="APPROVED"||d.status==="MATCH"?"APPROVED":"NOT APPROVED")+"</b>"+(d.note?"<br>"+esc(d.note):"")+"</li>").join("")+"</ul><p>Please sign in to DV Back Office to review the results and upload any required corrections.</p><p>Dream Valley Realty</p></div>";
 const sms="Dream Valley Realty: "+type+" review "+resultLabel+" for "+property+". Approved "+approved.length+", not approved "+rejected.length+". Check DV Back Office for details.";
 const outcomes:any[]=[];
 async function claim(channel:"email"|"sms"){
   const col=channel+"_status";
   const current=cycle[col];
   if(current==="SENT"||current==="SKIPPED")return {skip:true,status:current};
   if(current==="SENDING")return {skip:true,status:"SENDING"};
   const claimed=await db.from("dv_accounting_document_review_cycles").update({[col]:"SENDING",updated_at:new Date().toISOString()}).eq("id",cycle.id).eq(col,current).select("id").maybeSingle();
   return claimed.data?{skip:false}:{skip:true,status:"IN_PROGRESS"};
 }
 async function sendEmail(){
   if(!recipientEmail){await db.from("dv_accounting_document_review_cycles").update({email_status:"SKIPPED",email_error:"Agent email is missing."}).eq("id",cycle.id);outcomes.push({channel:"EMAIL",status:"SKIPPED"});return;}
   const c=await claim("email");if(c.skip){outcomes.push({channel:"EMAIL",status:c.status});return;}
   try{
     const cid=Deno.env.get("ZOHO_CLIENT_ID"),secret=Deno.env.get("ZOHO_CLIENT_SECRET");
     if(!cid||!secret)throw new Error("Zoho credentials are not configured.");
     const {data:integration}=await db.from("dv_accounting_private_integrations").select("secret_payload").eq("integration_key","zoho_mail").maybeSingle();
     const p=integration?.secret_payload;if(!p?.refresh_token)throw new Error("Zoho Mail is not connected.");
     const base=String(p.accounts_server||"https://accounts.zoho.com"),mail=String(p.mail_api_base||"https://mail.zoho.com");
     const rr=await fetch(base+"/oauth/v2/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({refresh_token:p.refresh_token,client_id:cid,client_secret:secret,grant_type:"refresh_token"})});
     const token=await rr.json();if(!rr.ok||!token.access_token)throw new Error("Zoho token refresh failed.");
     const headers={Authorization:"Zoho-oauthtoken "+token.access_token,Accept:"application/json"};
     const ar=await fetch(mail+"/api/accounts",{headers}),aj=await ar.json();if(!ar.ok)throw new Error("Could not access Zoho accounts.");
     const list=Array.isArray(aj?.data)?aj.data:[aj?.data].filter(Boolean);
     const acct=list.find((a:any)=>String(a.accountAddress||a.emailAddress||a.primaryEmailAddress||a.email||"").toLowerCase()==="admin@dvrealty.ca")||list[0];
     if(!acct?.accountId)throw new Error("Zoho sender account could not be found.");
     const sent=await fetch(mail+"/api/accounts/"+encodeURIComponent(String(acct.accountId))+"/messages",{method:"POST",headers:{...headers,"Content-Type":"application/json"},body:JSON.stringify({fromAddress:"submissions@dvrealty.ca",toAddress:recipientEmail,subject,content:html,mailFormat:"html"})});
     const payload=await sent.json().catch(()=>({}));if(!sent.ok||(payload?.status?.code&&Number(payload.status.code)>=400))throw new Error("Zoho rejected email (HTTP "+sent.status+").");
     await db.from("dv_accounting_document_review_cycles").update({email_status:"SENT",email_provider_id:payload?.data?.messageId||null,email_error:null,email_sent_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",cycle.id);
     outcomes.push({channel:"EMAIL",status:"SENT"});
   }catch(e){const msg=String((e as Error)?.message||"Email failed").slice(0,350);await db.from("dv_accounting_document_review_cycles").update({email_status:"FAILED",email_error:msg,updated_at:new Date().toISOString()}).eq("id",cycle.id);outcomes.push({channel:"EMAIL",status:"FAILED",reason:msg});}
 }
 async function sendSms(){
   if(!recipientPhone){await db.from("dv_accounting_document_review_cycles").update({sms_status:"SKIPPED",sms_error:"Agent phone is missing."}).eq("id",cycle.id);outcomes.push({channel:"SMS",status:"SKIPPED"});return;}
   const c=await claim("sms");if(c.skip){outcomes.push({channel:"SMS",status:c.status});return;}
   try{
     const sid=Deno.env.get("TWILIO_ACCOUNT_SID"),token=Deno.env.get("TWILIO_AUTH_TOKEN"),from=Deno.env.get("TWILIO_FROM_NUMBER");
     if(!sid||!token||!from)throw new Error("Twilio is not configured.");
     const sent=await fetch("https://api.twilio.com/2010-04-01/Accounts/"+encodeURIComponent(sid)+"/Messages.json",{method:"POST",headers:{Authorization:"Basic "+btoa(sid+":"+token),"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({To:recipientPhone,From:from,Body:sms})});
     const payload=await sent.json().catch(()=>({}));if(!sent.ok)throw new Error("Twilio rejected SMS (HTTP "+sent.status+").");
     await db.from("dv_accounting_document_review_cycles").update({sms_status:"SENT",sms_provider_id:payload.sid||null,sms_error:null,sms_sent_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",cycle.id);
     outcomes.push({channel:"SMS",status:"SENT"});
   }catch(e){const msg=String((e as Error)?.message||"SMS failed").slice(0,350);await db.from("dv_accounting_document_review_cycles").update({sms_status:"FAILED",sms_error:msg,updated_at:new Date().toISOString()}).eq("id",cycle.id);outcomes.push({channel:"SMS",status:"FAILED",reason:msg});}
 }
 await Promise.all([sendEmail(),sendSms()]);
 return json({ok:true,cycleId:cycle.id,cycleNumber:cycle.cycle_number,outcome,counts:{approved:approved.length,notApproved:rejected.length},outcomes});
});