import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const b64=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes));
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"Content-Type":"application/json"}});
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 try{
  const raw=await req.text(),signature=req.headers.get("x-square-hmacsha256-signature")||"";
  const key=Deno.env.get("SQUARE_WEBHOOK_SIGNATURE_KEY"),notificationUrl=Deno.env.get("SQUARE_AGENT_INVOICE_WEBHOOK_URL");
  if(!key||!notificationUrl)return reply({error:"Square invoice webhook is not configured."},503);
  const cryptoKey=await crypto.subtle.importKey("raw",new TextEncoder().encode(key),{name:"HMAC",hash:"SHA-256"},false,["sign"]);
  const digest=await crypto.subtle.sign("HMAC",cryptoKey,new TextEncoder().encode(notificationUrl+raw));
  if(b64(new Uint8Array(digest))!==signature)return reply({error:"Invalid signature."},401);
  const event=JSON.parse(raw);
  if(event.type!=="payment.updated")return reply({received:true,ignored:true});
  const eventPayment=event.data?.object?.payment;
  if(!eventPayment?.id||eventPayment.status!=="COMPLETED"||!eventPayment.order_id)return reply({received:true,ignored:true});
  const token=Deno.env.get("SQUARE_ACCESS_TOKEN");
  if(!token)return reply({error:"Square API credentials are not configured."},503);
  const environment=Deno.env.get("SQUARE_ENVIRONMENT")||"sandbox";
  if(!["sandbox","production"].includes(environment))return reply({error:"SQUARE_ENVIRONMENT must be sandbox or production."},503);
  const squareBase=environment==="production"?"https://connect.squareup.com":"https://connect.squareupsandbox.com";
  const paymentResponse=await fetch(squareBase+"/v2/payments/"+encodeURIComponent(eventPayment.id),{headers:{"Authorization":"Bearer "+token,"Square-Version":"2025-10-16"}});
  const paymentBody=await paymentResponse.json(),payment=paymentBody.payment;
  if(!paymentResponse.ok||!payment)return reply({error:"Could not verify payment with Square."},502);
  if(payment.status!=="COMPLETED"||payment.order_id!==eventPayment.order_id)return reply({received:true,ignored:true});
  const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const {data:session,error:sessionErr}=await db.from("dv_agent_invoice_square_sessions").select("id,invoice_id,agent_id,amount_cents,base_amount_cents,fee_amount_cents,fee_tax_cents,allocations,currency,status").eq("square_order_id",payment.order_id).maybeSingle();
  if(sessionErr)throw sessionErr;
  if(!session)return reply({received:true,matched:false});
  const paidCents=Number(payment.amount_money?.amount),currency=payment.amount_money?.currency;
  if(session.status==="PAID"||paidCents!==Number(session.amount_cents)||currency!==session.currency)return reply({received:true,matched:true,ignored:true});
  const allocations=Array.isArray(session.allocations)?session.allocations:[];
  if(!allocations.length)return reply({received:true,matched:true,ignored:true,reason:"Checkout allocation snapshot missing."},409);
  const allocationBase=allocations.reduce((sum:any,item:any)=>sum+Math.round(Number(item.amount||0)*100),0);
  const allocationFees=allocations.reduce((sum:any,item:any)=>sum+Math.round(Number(item.card_fee_amount||0)*100),0);
  const allocationTax=allocations.reduce((sum:any,item:any)=>sum+Math.round(Number(item.card_fee_tax||0)*100),0);
  if(allocationBase!==Number(session.base_amount_cents)||allocationFees!==Number(session.fee_amount_cents||0)||allocationTax!==Number(session.fee_tax_cents||0))return reply({error:"Saved invoice allocations do not match Square checkout."},409);
  const paymentDate=new Intl.DateTimeFormat("en-CA",{timeZone:"America/Toronto",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date(payment.created_at||Date.now()));
  const {data:recorded,error:recordErr}=await db.rpc("dv_record_agent_invoice_multi_payment",{
   p_agent_id:session.agent_id,
   p_allocations:allocations.map((item:any)=>({invoice_id:item.invoice_id,amount:item.amount,card_fee_amount:item.card_fee_amount,card_fee_tax:item.card_fee_tax})),
   p_payment_method:"Square",
   p_payment_date:paymentDate,
   p_reference_number:payment.id,
   p_square_payment_id:payment.id,
   p_notes:"Verified Square payment. Allocated oldest outstanding invoice first."
  });
  if(recordErr){
   const {data:existing}=await db.from("dv_agent_invoice_payments").select("id").eq("square_payment_id",payment.id).maybeSingle();
   if(!existing)throw recordErr;
  }
  const {error:updateErr}=await db.from("dv_agent_invoice_square_sessions").update({status:"PAID",square_payment_id:payment.id,paid_at:new Date().toISOString()}).eq("id",session.id).eq("status","PENDING");
  if(updateErr)throw updateErr;
  return reply({received:true,matched:true,recorded:!recordErr});
 }catch(e){return reply({error:e instanceof Error?e.message:"Webhook processing failed."},500)}
});