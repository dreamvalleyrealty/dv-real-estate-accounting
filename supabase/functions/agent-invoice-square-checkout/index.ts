import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"Method not allowed"},405);
 try{
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth=req.headers.get("Authorization")||"";
  const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const {data:userData,error:userError}=await userClient.auth.getUser();
  const user=userData.user;
  if(userError||!user?.email)return json({error:"Please sign in again."},401);
  const db=createClient(url,service);
  const body=await req.json(),invoiceId=String(body.invoice_id||"");
  if(!invoiceId)return json({error:"Invoice not found."},400);
  const {data:agent,error:agentErr}=await db.from("dv_accounting_agents").select("id,email,active").ilike("email",user.email).eq("active",true).maybeSingle();
  if(agentErr||!agent)return json({error:"Your login is not linked to an active agent profile."},403);
  const {data:invoice,error:invoiceErr}=await db.from("dv_agent_invoices").select("id,invoice_number,agent_id,total_amount,paid_amount,balance_amount,status").eq("id",invoiceId).eq("agent_id",agent.id).maybeSingle();
  if(invoiceErr||!invoice)return json({error:"Invoice not found."},404);
  const balance=Number(invoice.balance_amount||0),cents=Math.round(balance*100);
  if(cents<=0||invoice.status==="Void")return json({error:"This invoice has no payable balance."},409);
  const {data:pending,error:pendingErr}=await db.from("dv_agent_invoice_square_sessions").select("checkout_url,amount_cents").eq("invoice_id",invoice.id).eq("status","PENDING").maybeSingle();
  if(pendingErr)throw pendingErr;
  if(pending){
   if(Number(pending.amount_cents)!==cents)return json({error:"A previous Square checkout is still pending for a different balance. Contact the office before trying again."},409);
   return json({ok:true,checkout_url:pending.checkout_url,invoice_number:invoice.invoice_number,amount:balance,reused:true});
  }
  const token=Deno.env.get("SQUARE_ACCESS_TOKEN"),locationId=Deno.env.get("SQUARE_LOCATION_ID");
  if(!token||!locationId)return json({error:"Square credentials are not configured."},503);
  const environment=Deno.env.get("SQUARE_ENVIRONMENT")||"sandbox";
  if(!["sandbox","production"].includes(environment))return json({error:"SQUARE_ENVIRONMENT must be sandbox or production."},503);
  const squareBase=environment==="production"?"https://connect.squareup.com":"https://connect.squareupsandbox.com";
  const origin=new URL(req.headers.get("origin")||"https://localhost").origin;
  const idem=crypto.randomUUID();
  const square=await fetch(squareBase+"/v2/online-checkout/payment-links",{
   method:"POST",headers:{"Authorization":"Bearer "+token,"Content-Type":"application/json","Square-Version":"2025-10-16"},
   body:JSON.stringify({idempotency_key:idem,order:{location_id:locationId,reference_id:invoice.invoice_number,line_items:[{name:"Dream Valley Realty invoice "+invoice.invoice_number,quantity:"1",base_price_money:{amount:cents,currency:"CAD"}}]},checkout_options:{redirect_url:origin+"?agent_invoice_payment="+encodeURIComponent(invoice.invoice_number),merchant_support_email:"admin@dvrealty.ca"},pre_populated_data:{buyer_email:user.email}})
  });
  const result=await square.json();
  if(!square.ok||!result.payment_link?.url){const detail=result.errors?.find((x:any)=>x.detail)?.detail||"Square could not create checkout.";return json({error:detail},502)}
  const orderId=result.payment_link.order_id;
  if(!orderId)return json({error:"Square did not return an order reference."},502);
  const {error:saveErr}=await db.from("dv_agent_invoice_square_sessions").insert({invoice_id:invoice.id,agent_id:agent.id,square_order_id:orderId,square_payment_link_id:result.payment_link.id,checkout_url:result.payment_link.url,amount_cents:cents,currency:"CAD"});
  if(saveErr){
   const {data:existing}=await db.from("dv_agent_invoice_square_sessions").select("checkout_url,amount_cents").eq("invoice_id",invoice.id).eq("status","PENDING").maybeSingle();
   if(existing&&Number(existing.amount_cents)===cents)return json({ok:true,checkout_url:existing.checkout_url,invoice_number:invoice.invoice_number,amount:balance,reused:true});
   throw saveErr;
  }
  return json({ok:true,checkout_url:result.payment_link.url,invoice_number:invoice.invoice_number,amount:balance});
 }catch(e){return json({error:e instanceof Error?e.message:"Checkout could not be started."},500)}
});