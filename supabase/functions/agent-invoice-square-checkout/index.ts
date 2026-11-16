import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
const invoiceBalance=(i:any)=>Number(Math.max(Number(i.total_amount||0)-Number(i.paid_amount||0),0).toFixed(2));
const cardFeeFor=(i:any,b:number)=>{if(!i.card_fee_enabled||Number(i.card_fee_percentage)<=0)return {fee:0,tax:0};const total=Number(i.total_amount||0),sub=Number(i.subtotal||0),base=i.card_fee_basis==="TOTAL_INCL_HST"?b:(total>0?sub*b/total:0);const fee=Number((base*Number(i.card_fee_percentage)/100).toFixed(2));const tax=Number((fee*Number(i.card_fee_tax_rate??13)/100).toFixed(2));return {fee,tax};};

Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 try{
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("Authorization")||"",userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const {data:userData,error:userError}=await userClient.auth.getUser(),user=userData.user;
  if(userError||!user?.email)return json({error:"Please sign in again."},401);
  const db=createClient(url,service),body=await req.json(),invoiceId=String(body.invoice_id||"");
  if(!invoiceId)return json({error:"Invoice not found."},400);
  const {data:profile}=await db.from("dv_accounting_user_profiles").select("role").eq("user_id",user.id).maybeSingle();
  const role=String(user.app_metadata?.role||user.app_metadata?.user_role||profile?.role||"").toUpperCase().replace(/[^A-Z]/g,"");
  const isAdmin=["ADMIN","ADMINISTRATOR","SUPERADMIN","SUPERADMINISTRATOR","BROKER","BROKEROFRECORD","OFFICEADMIN","TRADEADMIN"].includes(role)||String(user.email).toLowerCase()==="admin@dvrealty.ca";
  const {data:current,error:currentErr}=await db.from("dv_agent_invoices").select("id,invoice_number,agent_id,status,total_amount,paid_amount").eq("id",invoiceId).maybeSingle();
  if(currentErr||!current)return json({error:"Invoice not found."},404);
  if(!current.agent_id)return json({error:"Card payment is unavailable for external invoices. Please use e-transfer."},409);
  const {data:agent,error:agentErr}=await db.from("dv_accounting_agents").select("id,email,active").eq("id",current.agent_id).maybeSingle();
  if(agentErr||!agent?.active||!agent.email)return json({error:"The invoice agent profile is not active or has no email address."},409);
  if(!isAdmin&&String(agent.email).trim().toLowerCase()!==String(user.email).trim().toLowerCase())return json({error:"You can only create checkout links for your own invoices."},403);
  const {data:invoices,error:invoicesErr}=await db.from("dv_agent_invoices").select("id,invoice_number,invoice_date,created_at,subtotal,total_amount,balance_amount,paid_amount,status,card_fee_enabled,card_fee_percentage,card_fee_basis,card_fee_tax_rate").eq("agent_id",current.agent_id).neq("status","Void").gt("balance_amount",0).order("invoice_date",{ascending:true}).order("created_at",{ascending:true}).order("invoice_number",{ascending:true});
  if(invoicesErr)throw invoicesErr;
  if(!invoices?.length)return json({error:"There are no outstanding invoices."},409);
  const allocations=invoices.map((i:any)=>{const amount=invoiceBalance(i),fee=cardFeeFor(i,amount);return {invoice_id:i.id,invoice_number:i.invoice_number,amount:Number(amount.toFixed(2)),card_fee_amount:fee.fee,card_fee_tax:fee.tax};});
  const baseCents=allocations.reduce((s:any,x:any)=>s+Math.round(x.amount*100),0);
  const feeCents=allocations.reduce((s:any,x:any)=>s+Math.round(x.card_fee_amount*100),0);
  const feeTaxCents=allocations.reduce((s:any,x:any)=>s+Math.round(x.card_fee_tax*100),0),cents=baseCents+feeCents+feeTaxCents;
  if(cents<=0)return json({error:"There is no payable balance."},409);
  const {data:pending,error:pendingErr}=await db.from("dv_agent_invoice_square_sessions").select("checkout_url,amount_cents,allocations").eq("invoice_id",invoiceId).eq("status","PENDING").maybeSingle();
  if(pendingErr)throw pendingErr;
  if(pending){if(Number(pending.amount_cents)===cents&&JSON.stringify(pending.allocations||[])===JSON.stringify(allocations))return json({ok:true,checkout_url:pending.checkout_url,reused:true,invoice_count:allocations.length,total:cents/100});return json({error:"A previous Square checkout is pending. Contact the office before starting another payment."},409);}
  const token=Deno.env.get("SQUARE_ACCESS_TOKEN"),locationId=Deno.env.get("SQUARE_LOCATION_ID"),environment=Deno.env.get("SQUARE_ENVIRONMENT")||"sandbox";
  if(!token||!locationId)return json({error:"Square credentials are not configured."},503);
  if(!["sandbox","production"].includes(environment))return json({error:"SQUARE_ENVIRONMENT must be sandbox or production."},503);
  const squareBase=environment==="production"?"https://connect.squareup.com":"https://connect.squareupsandbox.com";
  const orderName="Dream Valley Realty invoices "+allocations.map((x:any)=>x.invoice_number).join(", ");
  const square=await fetch(squareBase+"/v2/online-checkout/payment-links",{method:"POST",headers:{"Authorization":"Bearer "+token,"Content-Type":"application/json","Square-Version":"2025-10-16"},body:JSON.stringify({idempotency_key:crypto.randomUUID(),order:{location_id:locationId,reference_id:current.invoice_number,line_items:[{name:orderName,quantity:"1",base_price_money:{amount:cents,currency:"CAD"}}]},checkout_options:{merchant_support_email:"admin@dvrealty.ca"},pre_populated_data:{buyer_email:agent.email}})});
  const result=await square.json();
  if(!square.ok||!result.payment_link?.url||!result.payment_link?.order_id)return json({error:result.errors?.find((x:any)=>x.detail)?.detail||"Square could not create checkout."},502);
  const {error:saveErr}=await db.from("dv_agent_invoice_square_sessions").insert({invoice_id:invoiceId,agent_id:current.agent_id,square_order_id:result.payment_link.order_id,square_payment_link_id:result.payment_link.id,checkout_url:result.payment_link.url,amount_cents:cents,base_amount_cents:baseCents,fee_amount_cents:feeCents,fee_tax_cents:feeTaxCents,allocations,currency:"CAD"});
  if(saveErr)throw saveErr;
  return json({ok:true,checkout_url:result.payment_link.url,invoice_count:allocations.length,base_amount:baseCents/100,card_fee:feeCents/100,card_fee_tax:feeTaxCents/100,card_total:cents/100});
 }catch(e){return json({error:e instanceof Error?e.message:"Checkout could not be started."},500)}
});
