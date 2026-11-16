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
  const paymentResponse=await fetch("https://connect.squareupsandbox.com/v2/payments/"+encodeURIComponent(eventPayment.id),{headers:{"Authorization":"Bearer "+token,"Square-Version":"2025-10-16"}});
  const paymentBody=await paymentResponse.json(),payment=paymentBody.payment;
  if(!paymentResponse.ok||!payment)return reply({error:"Could not verify payment with Square."},502);
  if(payment.status!=="COMPLETED"||payment.order_id!==eventPayment.order_id)return reply({received:true,ignored:true});
  const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const {data:session,error:sessionErr}=await db.from("dv_agent_invoice_square_sessions").select("id,invoice_id,agent_id,amount_cents,currency,status").eq("square_order_id",payment.order_id).maybeSingle();
  if(sessionErr)throw sessionErr;
  if(!session)return reply({received:true,matched:false});
  const paidCents=Number(payment.amount_money?.amount),currency=payment.amount_money?.currency;
  if(session.status==="PAID"||paidCents!==Number(session.amount_cents)||currency!==session.currency)return reply({received:true,matched:true,ignored:true});
  const {data:invoice,error:invoiceErr}=await db.from("dv_agent_invoices").select("id,agent_id,balance_amount").eq("id",session.invoice_id).maybeSingle();
  if(invoiceErr)throw invoiceErr;
  if(!invoice||invoice.agent_id!==session.agent_id||Math.round(Number(invoice.balance_amount||0)*100)!==paidCents)return reply({received:true,matched:true,ignored:true});
  const {error:insertErr}=await db.from("dv_agent_invoice_payments").insert({invoice_id:session.invoice_id,agent_id:session.agent_id,amount:paidCents/100,payment_date:new Date().toISOString().slice(0,10),payment_method:"Credit card (Square)",reference_number:payment.id,notes:"Verified by Square payment webhook.",square_payment_id:payment.id});
  if(insertErr&&insertErr.code!=="23505")throw insertErr;
  const {error:updateErr}=await db.from("dv_agent_invoice_square_sessions").update({status:"PAID",square_payment_id:payment.id,paid_at:new Date().toISOString()}).eq("id",session.id).eq("status","PENDING");
  if(updateErr)throw updateErr;
  return reply({received:true,matched:true,recorded:!insertErr});
 }catch(e){return reply({error:e instanceof Error?e.message:"Webhook processing failed."},500)}
});