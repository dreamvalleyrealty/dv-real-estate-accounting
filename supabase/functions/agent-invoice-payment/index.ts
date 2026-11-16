import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"GET, POST, OPTIONS"};
const json=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const hash=async(s:string)=>Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s)))).map(x=>x.toString(16).padStart(2,"0")).join("");
const esc=(s:unknown)=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]!));
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const db=createClient(url,key,{auth:{persistSession:false}});
 try{
  if(req.method==="POST"){
   const b=await req.json().catch(()=>({}));
   if(b.action==="create_link"){
    const auth=req.headers.get("Authorization")||"";
    const uc=createClient(url,anon,{global:{headers:{Authorization:auth}}});
    const {data:u,error:ue}=await uc.auth.getUser();
    if(ue||!u.user?.email)return json({error:"Please sign in again."},401);
    const {data:p}=await db.from("dv_accounting_user_profiles").select("role").eq("user_id",u.user.id).maybeSingle();
    const role=String(u.user.app_metadata?.role||u.user.app_metadata?.user_role||p?.role||"").toUpperCase().replace(/[^A-Z]/g,"");
    if(!["ADMIN","ADMINISTRATOR","SUPERADMIN","SUPERADMINISTRATOR","BROKER","BROKEROFRECORD","OFFICEADMIN","TRADEADMIN"].includes(role)&&String(u.user.email).toLowerCase()!=="admin@dvrealty.ca")return json({error:"Administrator access required."},403);
    const {data:i}=await db.from("dv_agent_invoices").select("id,balance_amount,status").eq("id",String(b.invoice_id||"")).maybeSingle();
    if(!i)return json({error:"Invoice not found."},404);
    if(Number(i.balance_amount)<=0||i.status==="Void")return json({error:"No outstanding balance."},409);
    const raw=Array.from(crypto.getRandomValues(new Uint8Array(32))).map(v=>v.toString(16).padStart(2,"0")).join("");
    const {error:e}=await db.from("dv_agent_invoice_payment_links").insert({invoice_id:i.id,token_hash:await hash(raw),created_by:u.user.id});
    if(e)throw e;
    return json({ok:true,payment_url:"https://dvbo.up.railway.app/payment.html?token="+raw});
   }
   const token=String(b.token||"");
   if(!/^[a-f0-9]{64}$/i.test(token))return json({error:"Invalid payment link."},400);
   const {data:l}=await db.from("dv_agent_invoice_payment_links").select("id,invoice_id,expires_at,revoked_at").eq("token_hash",await hash(token)).maybeSingle();
   if(!l||l.revoked_at||new Date(l.expires_at)<new Date())return json({error:"Payment link expired or invalid."},404);
   const {data:i}=await db.from("dv_agent_invoices").select("id,invoice_number,agent_id,balance_amount,status").eq("id",l.invoice_id).maybeSingle();
   if(!i||Number(i.balance_amount)<=0||i.status==="Void")return json({error:"No outstanding balance."},409);
   if(b.action==="details")return json({ok:true,invoice_number:i.invoice_number,balance_amount:Number(i.balance_amount),card:Boolean(i.agent_id)});
   if(b.action==="submit_etransfer"){
    const ref=String(b.reference_number||"").trim();
    if(ref.length<3||ref.length>120)return json({error:"Enter a reference number between 3 and 120 characters."},400);
    const {data:dup}=await db.from("dv_agent_invoice_payment_submissions").select("id").eq("invoice_id",i.id).eq("reference_number",ref).maybeSingle();
    if(dup)return json({error:"That reference number has already been submitted for this invoice."},409);
    const {error:e}=await db.from("dv_agent_invoice_payment_submissions").insert({invoice_id:i.id,agent_id:i.agent_id,amount:Number(i.balance_amount),payment_method:"E-transfer",reference_number:ref});
    if(e)throw e;
    return json({ok:true,message:"Reference submitted. The office will verify the bank deposit before marking this invoice paid."});
   }
   if(b.action==="square"){
    if(!i.agent_id)return json({error:"Card payment is unavailable for this invoice. Please use e-transfer."},409);
    const {data:a}=await db.from("dv_accounting_agents").select("email,active").eq("id",i.agent_id).maybeSingle();
    if(!a?.active||!a.email)return json({error:"Agent profile unavailable."},409);
    const cents=Math.round(Number(i.balance_amount)*100);
    const {data:pending}=await db.from("dv_agent_invoice_square_sessions").select("checkout_url,amount_cents").eq("invoice_id",i.id).eq("status","PENDING").maybeSingle();
    if(pending&&Number(pending.amount_cents)===cents)return json({ok:true,checkout_url:pending.checkout_url});
    if(pending)return json({error:"A previous Square checkout is pending for a different balance. Contact the office."},409);
    const sq=Deno.env.get("SQUARE_ACCESS_TOKEN"),loc=Deno.env.get("SQUARE_LOCATION_ID"),env=Deno.env.get("SQUARE_ENVIRONMENT")||"sandbox";
    if(!sq||!loc)return json({error:"Square is not configured."},503);
    const base=env==="production"?"https://connect.squareup.com":"https://connect.squareupsandbox.com";
    const r=await fetch(base+"/v2/online-checkout/payment-links",{method:"POST",headers:{"Authorization":"Bearer "+sq,"Content-Type":"application/json","Square-Version":"2025-10-16"},body:JSON.stringify({idempotency_key:crypto.randomUUID(),order:{location_id:loc,reference_id:i.invoice_number,line_items:[{name:"Dream Valley Realty invoice "+i.invoice_number,quantity:"1",base_price_money:{amount:cents,currency:"CAD"}}]},checkout_options:{merchant_support_email:"admin@dvrealty.ca"},pre_populated_data:{buyer_email:a.email}})});
    const sr=await r.json();
    if(!r.ok||!sr.payment_link?.url||!sr.payment_link?.order_id)return json({error:sr.errors?.[0]?.detail||"Square checkout failed."},502);
    const {error:e}=await db.from("dv_agent_invoice_square_sessions").insert({invoice_id:i.id,agent_id:i.agent_id,square_order_id:sr.payment_link.order_id,square_payment_link_id:sr.payment_link.id,checkout_url:sr.payment_link.url,amount_cents:cents,currency:"CAD"});
    if(e)throw e;
    return json({ok:true,checkout_url:sr.payment_link.url});
   }
   return json({error:"Unsupported action."},400);
  }
  if(req.method!=="GET")return json({error:"Method not allowed."},405);
  const token=new URL(req.url).searchParams.get("token")||"";
  if(!/^[a-f0-9]{64}$/i.test(token))return new Response("<h2>Invalid payment link</h2>",{status:404,headers:{"Content-Type":"text/html; charset=utf-8","Content-Disposition":"inline","X-Content-Type-Options":"nosniff"}});
  const {data:l}=await db.from("dv_agent_invoice_payment_links").select("invoice_id,expires_at,revoked_at").eq("token_hash",await hash(token)).maybeSingle();
  if(!l||l.revoked_at||new Date(l.expires_at)<new Date())return new Response("<h2>Payment link expired. Contact admin@dvrealty.ca.</h2>",{status:404,headers:{"Content-Type":"text/html"}});
  const {data:i}=await db.from("dv_agent_invoices").select("invoice_number,agent_id,balance_amount,status").eq("id",l.invoice_id).maybeSingle();
  if(!i||Number(i.balance_amount)<=0||i.status==="Void")return new Response("<h2>No payment due.</h2>",{headers:{"Content-Type":"text/html"}});
  const amount=new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(i.balance_amount));
  const card=Boolean(i.agent_id);
  const html=`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Dream Valley Realty invoice payment</title><style>body{margin:0;background:#f3f5f8;font-family:Arial;color:#243047}.wrap{max-width:600px;margin:32px auto;padding:16px}.panel{background:white;border-radius:12px;overflow:hidden}.head{background:#0f2141;color:white;padding:24px;border-bottom:4px solid #9e8556}.body{padding:24px}.amount{font-size:30px;color:#0f2141;font-weight:bold;margin:18px 0}.choice{border:1px solid #dfe4eb;border-radius:8px;padding:16px;margin:14px 0}.muted{font-size:13px;line-height:1.5;color:#687386}input{box-sizing:border-box;width:100%;padding:12px;border:1px solid #cbd2dc;border-radius:6px;margin:8px 0 12px;font-size:16px}.btn{width:100%;padding:13px;background:#9e8556;color:white;border:0;border-radius:6px;font-weight:bold}.msg{display:none;padding:12px;background:#f3f5f8;margin-top:12px}</style></head><body><div class="wrap"><div class="panel"><div class="head"><b>DREAM VALLEY REALTY INC.</b><div class="muted" style="color:#dbe2ed">INVOICE PAYMENT</div></div><div class="body"><div class="muted">Invoice ${esc(i.invoice_number)}</div><div class="amount">${amount} CAD</div><section class="choice"><h3>E-transfer</h3><p class="muted">Send payment to <b>admin@dvrealty.ca</b>. Include invoice ${esc(i.invoice_number)} in your transfer message. After sending, enter the e-transfer reference number below.</p><label for="ref">E-transfer reference number</label><input id="ref" maxlength="120" minlength="3" placeholder="Enter reference number"><button class="btn" id="send">Submit reference</button></section>${card?`<section class="choice"><h3>Credit card (Square)</h3><p class="muted">Secure card payment. No additional fee is currently applied.</p><button class="btn" id="card">Continue to Square</button></section>`:""}<p class="muted">Submitting a reference does not mark the invoice as paid. The office will verify the deposit first.</p><div class="msg" id="msg"></div></div></div></div><script>const token="${token}",msg=document.getElementById("msg");function show(t){msg.style.display="block";msg.textContent=t}document.getElementById("send").onclick=async()=>{let ref=document.getElementById("ref").value.trim(),b=document.getElementById("send");if(ref.length<3){show("Enter the e-transfer reference number.");return}b.disabled=true;try{let r=await fetch(location.href,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"submit_etransfer",token,reference_number:ref})}),d=await r.json();if(!r.ok)throw Error(d.error);show(d.message);document.getElementById("ref").value=""}catch(e){show(e.message)}finally{b.disabled=false}};let c=document.getElementById("card");if(c)c.onclick=async()=>{c.disabled=true;try{let r=await fetch(location.href,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action:"square",token})}),d=await r.json();if(!r.ok)throw Error(d.error);location.href=d.checkout_url}catch(e){show(e.message);c.disabled=false}};</script></body></html>`;
  return new Response(html,{headers:{"Content-Type":"text/html; charset=utf-8","Content-Disposition":"inline","X-Content-Type-Options":"nosniff","Cache-Control":"no-store"}});
 }catch(e){return req.method==="GET"?new Response("<h2>Payment page unavailable. Contact admin@dvrealty.ca.</h2>",{status:500,headers:{"Content-Type":"text/html"}}):json({error:e instanceof Error?e.message:"Payment request failed."},500)}
});