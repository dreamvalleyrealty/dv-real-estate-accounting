import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
function json(body:unknown,status=200){return new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}})}
const validEmail=(v:string)=>/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
function decodeBase64(input:string){const raw=atob(input);const bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);return bytes;}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 const auth=req.headers.get("Authorization")||"";
 if(!auth.startsWith("Bearer "))return json({error:"Sign in before sending email."},401);
 const supabaseUrl=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),clientId=Deno.env.get("ZOHO_CLIENT_ID"),clientSecret=Deno.env.get("ZOHO_CLIENT_SECRET");
 if(!supabaseUrl||!serviceKey||!clientId||!clientSecret)return json({error:"Zoho email service is not configured."},503);
 const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
 const {data:userData,error:userError}=await admin.auth.getUser(auth.slice(7));
 if(userError||!userData?.user)return json({error:"Your session could not be verified. Please sign in again."},401);
 let body:any;try{body=await req.json()}catch{return json({error:"Invalid request body."},400)}
 const recipient=String(body.to||"").trim(),cc=String(body.cc||"").trim(),subject=String(body.subject||"").trim(),html=String(body.htmlBody||"").trim();
 const documentType=String(body.documentType||"");
 const lawyerPackage=documentType==="LAWYER_DOCUMENT_PACKAGE";
 if(!validEmail(recipient)||(cc&&!validEmail(cc)))return json({error:"Enter a valid recipient email address."},400);
 if(!subject||subject.length>250||!html||html.length>40000)return json({error:"Subject or email body is missing or too long."},400);
 if(!["COMMISSION_INVOICE","SELLER_COMMISSION_STATEMENT","LAWYER_DOCUMENT_PACKAGE"].includes(documentType))return json({error:"Unsupported document type."},400);
 const files:any[]=[];
 if(lawyerPackage){
  if(!Array.isArray(body.attachments)||body.attachments.length<1||body.attachments.length>15)return json({error:"Select between 1 and 15 trade documents."},400);
  let totalBytes=0;
  for(const item of body.attachments){
   const name=String(item?.name||"").trim(),encoded=String(item?.base64||"");
   if(!/^[A-Za-z0-9._ -]{1,160}\.(pdf|jpg|jpeg|png|doc|docx|xls|xlsx|tif|tiff)$/i.test(name)||!encoded||encoded.length>12000000)return json({error:"One of the selected documents has an invalid name, type, or size."},400);
   let bytes:Uint8Array;try{bytes=decodeBase64(encoded)}catch{return json({error:"A selected document could not be decoded: "+name},400)}
   if(!bytes.length||bytes.length>8*1024*1024)return json({error:"Each attachment must be no larger than 8 MB: "+name},400);
   totalBytes+=bytes.length;if(totalBytes>16*1024*1024)return json({error:"The selected documents exceed the 16 MB total attachment limit."},400);
   files.push({name,bytes});
  }
 }else{
  const attachmentName=String(body.attachmentName||"").trim(),base64=String(body.attachmentBase64||"");
  if(!/^[A-Za-z0-9._ -]{1,160}\.pdf$/i.test(attachmentName)||!base64||base64.length>12000000)return json({error:"Attach a valid PDF (maximum about 8 MB)."},400);
  let bytes:Uint8Array;try{bytes=decodeBase64(base64)}catch{return json({error:"The PDF attachment could not be decoded."},400)}
  if(bytes.length<5||bytes[0]!==37||bytes[1]!==80||bytes[2]!==68||bytes[3]!==70||bytes.length>8*1024*1024)return json({error:"The attachment must be a valid PDF no larger than 8 MB."},400);
  files.push({name:attachmentName,bytes});
 }
 const {data:profileRoleData}=await admin.from("dv_accounting_user_profiles").select("role").eq("user_id",userData.user.id).maybeSingle();
 const role=String(userData.user.app_metadata?.role||userData.user.app_metadata?.user_role||userData.user.user_metadata?.role||userData.user.user_metadata?.user_role||profileRoleData?.role||"").toUpperCase().replace(/[^A-Z]/g,"");
 const adminRoles=["ADMIN","ADMINISTRATOR","SUPERADMIN","SUPERADMINISTRATOR","BROKER","BROKEROFRECORD","OFFICEADMIN","TRADEADMIN"];
 const isAdmin=adminRoles.includes(role)||String(userData.user.email||"").toLowerCase()==="admin@dvrealty.ca";
 const from=lawyerPackage?(isAdmin?"admin@dvrealty.ca":String(userData.user.email||"").trim()):String(body.fromEmail||"admin@dvrealty.ca");
 if(!validEmail(from))return json({error:"Your signed-in account does not have a valid sender email address."},400);
 if(lawyerPackage&&String(body.fromEmail||"").toLowerCase()!==from.toLowerCase())return json({error:"The sender address must match your signed-in account or the authorized brokerage admin address."},403);
 if(lawyerPackage&&String(body.senderMode||"").toLowerCase()==="admin"&&!isAdmin)return json({error:"Only an authorized administrator can send from admin@dvrealty.ca."},403);
 const {data:integration,error:integrationError}=await admin.from("dv_accounting_private_integrations").select("secret_payload").eq("integration_key","zoho_mail").maybeSingle();
 if(integrationError||!integration?.secret_payload?.refresh_token)return json({error:"Zoho Mail is not connected. Reconnect the mailbox first."},503);
 const p=integration.secret_payload,accountsServer=String(p.accounts_server||"https://accounts.zoho.com"),mailBase=String(p.mail_api_base||"https://mail.zoho.com"),configuredFrom=String(p.sender_email||"admin@dvrealty.ca");
 const refresh=await fetch(accountsServer+"/oauth/v2/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({refresh_token:p.refresh_token,client_id:clientId,client_secret:clientSecret,grant_type:"refresh_token"})});
 const token=await refresh.json().catch(()=>({}));
 if(!refresh.ok||!token.access_token)return json({error:"Zoho token refresh failed. Reconnect Zoho Mail and try again.",providerStatus:refresh.status,providerError:token.error||null},502);
 const headers={Authorization:"Zoho-oauthtoken "+token.access_token,Accept:"application/json"};
 const ar=await fetch(mailBase+"/api/accounts",{headers});
 const accountJson=await ar.json().catch(()=>({}));
 if(!ar.ok)return json({error:"Could not access Zoho Mail accounts.",providerStatus:ar.status},502);
 const list=Array.isArray(accountJson?.data)?accountJson.data:Array.isArray(accountJson)?accountJson:(accountJson?.data&&typeof accountJson.data==="object"?[accountJson.data]:[]);
 const acct=list.find((a:any)=>String(a.accountAddress||a.emailAddress||a.primaryEmailAddress||a.email||"").toLowerCase()===from.toLowerCase())||list.find((a:any)=>String(a.accountAddress||a.emailAddress||a.primaryEmailAddress||a.email||"").toLowerCase()===configuredFrom.toLowerCase())||list.find((a:any)=>String(a.accountName||"").toLowerCase().includes("admin"))||list[0];
 const accountId=acct?.accountId||acct?.account_id||acct?.id;
 if(!accountId)return json({error:"Zoho returned account data but no account ID could be identified. Please contact the administrator.",accountFields:acct?Object.keys(acct):[]},502);
 const attachmentNames=files.map(f=>f.name).join("; ");
 const {data:log,error:logError}=await admin.from("dv_accounting_email_log").insert({transaction_id:body.transactionId||null,document_type:documentType,recipient_email:recipient,cc_email:cc||null,subject,attachment_name:attachmentNames,status:"PENDING",sent_by:userData.user.id,sent_by_email:from}).select("id").single();
 if(logError)return json({error:"Could not create the email audit record. No email was sent."},500);
 try{
  const uploadedAttachments:any[]=[];
  for(const file of files){
   const uploadUrl=new URL(mailBase+"/api/accounts/"+encodeURIComponent(String(accountId))+"/messages/attachments");uploadUrl.searchParams.set("fileName",file.name);uploadUrl.searchParams.set("isInline","false");
   // Zoho's raw-file upload accepts binary bytes; use octet-stream for reliable attachment uploads.
   const upload=await fetch(uploadUrl.toString(),{method:"POST",headers:{...headers,"Content-Type":"application/octet-stream"},body:file.bytes});
   const uploadJson=await upload.json().catch(()=>({})),uploaded=uploadJson?.data;
   if(!upload.ok||!uploaded?.storeName||!uploaded?.attachmentName||!uploaded?.attachmentPath)throw new Error("Zoho attachment upload failed for "+file.name+" (HTTP "+upload.status+(uploadJson?.status?.description?": "+String(uploadJson.status.description).slice(0,160):"")+(uploadJson?.errorCode?"; "+String(uploadJson.errorCode).slice(0,100):"")+").");
   uploadedAttachments.push({storeName:uploaded.storeName,attachmentName:uploaded.attachmentName,attachmentPath:uploaded.attachmentPath});
  }
  const sendBody:any={fromAddress:from,toAddress:recipient,subject,content:html,mailFormat:"html",attachments:uploadedAttachments};if(cc)sendBody.ccAddress=cc;
  const sent=await fetch(mailBase+"/api/accounts/"+encodeURIComponent(String(accountId))+"/messages",{method:"POST",headers:{...headers,"Content-Type":"application/json"},body:JSON.stringify(sendBody)});
  const sentJson=await sent.json().catch(()=>({}));
  if(!sent.ok||(sentJson?.status?.code&&Number(sentJson.status.code)>=400))throw new Error("Zoho rejected the email request (HTTP "+sent.status+(sentJson?.status?.description?": "+String(sentJson.status.description).slice(0,160):"")+(sentJson?.data?.moreInfo?"; "+String(sentJson.data.moreInfo).slice(0,120):"")+").");
  const providerId=sentJson?.data?.messageId||sentJson?.data?.message_id||sentJson?.messageId||null;
  await admin.from("dv_accounting_email_log").update({status:"SENT",provider_message_id:providerId,provider_response:{status:sentJson?.status||null},sent_at:new Date().toISOString()}).eq("id",log.id);
  return json({ok:true,logId:log.id,status:"SENT",message:"Zoho accepted the email request. This confirms API acceptance, not guaranteed delivery."});
 }catch(e){
  const msg=String((e as Error)?.message||"Email sending failed").slice(0,400);
  await admin.from("dv_accounting_email_log").update({status:"FAILED",error_message:msg}).eq("id",log.id);
  return json({error:msg,logId:log.id},502);
 }
});