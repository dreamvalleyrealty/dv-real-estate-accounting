import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function validSignature(rawBody: string, signature: string, notificationUrl: string, key: string) {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey("raw", encoder.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(notificationUrl + rawBody));
  const expected = btoa(String.fromCharCode(...new Uint8Array(digest)));
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const rawBody = await req.text();
    const signature = req.headers.get("x-square-hmacsha256-signature") || "";
    const signatureKey = Deno.env.get("SQUARE_WEBHOOK_SIGNATURE_KEY") || "";
    const notificationUrl = Deno.env.get("SQUARE_WEBHOOK_NOTIFICATION_URL") || "";
    if (!signatureKey || !notificationUrl) return json({ error: "Webhook signature settings are not configured." }, 503);
    if (!signature || !(await validSignature(rawBody, signature, notificationUrl, signatureKey))) return json({ error: "Invalid webhook signature." }, 401);

    const event = JSON.parse(rawBody);
    const eventType = String(event.type || "").toLowerCase();
    const token = Deno.env.get("SQUARE_ACCESS_TOKEN");
    const environment = Deno.env.get("SQUARE_ENVIRONMENT") || "sandbox";
    if (!token || !["sandbox", "production"].includes(environment)) return json({ error: "Square API settings are not configured." }, 503);
    const squareBase = environment === "production" ? "https://connect.squareup.com" : "https://connect.squareupsandbox.com";
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    if (["refund.created", "refund.updated"].includes(eventType)) {
      const refundId = event.data?.id || event.data?.object?.refund?.id;
      if (!refundId) return json({ ok: true, ignored: true });
      const response = await fetch(squareBase + "/v2/refunds/" + encodeURIComponent(refundId), {
        headers: { "Authorization": "Bearer " + token, "Square-Version": "2025-10-16" }
      });
      const result = await response.json();
      if (!response.ok || !result.refund) return json({ error: "Could not verify refund with Square." }, 502);
      const refund = result.refund;
      const status = refund.status === "COMPLETED" ? "COMPLETED" : refund.status === "FAILED" ? "FAILED" : refund.status === "REJECTED" ? "REJECTED" : "PENDING";
      const { data: existing, error: lookupError } = await db.from("dv_agent_invoice_refunds")
        .select("id").eq("square_refund_id", refund.id).maybeSingle();
      if (lookupError) throw lookupError;
      if (!existing) return json({ ok: true, ignored: true, reason: "Refund is not linked to an invoice." });
      const { error: updateError } = await db.from("dv_agent_invoice_refunds").update({
        status, updated_at: new Date().toISOString(),
        completed_at: status === "COMPLETED" ? (refund.updated_at || new Date().toISOString()) : null
      }).eq("id", existing.id);
      if (updateError) throw updateError;
      return json({ ok: true, refund_status: status });
    }

    if (!["payment.created", "payment.updated"].includes(eventType)) return json({ ok: true, ignored: true });
    const paymentId = event.data?.id || event.data?.object?.payment?.id;
    if (!paymentId) return json({ ok: true, ignored: true });

    const squareResponse = await fetch(squareBase + "/v2/payments/" + encodeURIComponent(paymentId), { headers: { "Authorization": "Bearer " + token, "Square-Version": "2025-10-16" } });
    const squarePayload = await squareResponse.json();
    if (!squareResponse.ok || !squarePayload.payment) return json({ error: "Could not verify payment with Square." }, 502);
    const payment = squarePayload.payment;
    if (payment.status !== "COMPLETED") return json({ ok: true, ignored: true, status: payment.status });
    if (payment.amount_money?.currency !== "CAD" || !payment.order_id) return json({ ok: true, ignored: true });

    const { data: session, error: sessionError } = await db.from("dv_agent_invoice_square_sessions")
      .select("id,invoice_id,agent_id,square_order_id,amount_cents,base_amount_cents,fee_amount_cents,fee_tax_cents,status,square_payment_id")
      .eq("square_order_id", payment.order_id).maybeSingle();
    if (sessionError) throw sessionError;
    if (!session) return json({ ok: true, ignored: true, reason: "No matching invoice checkout." });
    if (Number(payment.amount_money?.amount) !== Number(session.amount_cents)) return json({ error: "Payment amount does not match the invoice checkout." }, 409);
    if (session.status === "PAID") return json({ ok: true, duplicate: true });
    if (session.status !== "PENDING") return json({ ok: true, ignored: true, reason: "Checkout is not pending." });

    const paymentDate = payment.created_at
      ? new Intl.DateTimeFormat("en-CA", { timeZone: "America/Toronto", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(payment.created_at))
      : new Intl.DateTimeFormat("en-CA", { timeZone: "America/Toronto", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());

    const { error: insertError } = await db.from("dv_agent_invoice_payments").insert({
      invoice_id: session.invoice_id, agent_id: session.agent_id,
      amount: (Number(session.base_amount_cents ?? session.amount_cents) / 100).toFixed(2),
      card_fee_amount: (Number(session.fee_amount_cents || 0) / 100).toFixed(2),
      card_fee_tax: (Number(session.fee_tax_cents || 0) / 100).toFixed(2),
      payment_date: paymentDate, payment_method: "Square", reference_number: payment.id,
      notes: Number(session.fee_amount_cents||0)+Number(session.fee_tax_cents||0)>0 ? "Online Square payment. Card fee and fee HST recorded separately." : "Online payment through Square", square_payment_id: payment.id
    });
    if (insertError) {
      const { data: existing } = await db.from("dv_agent_invoice_payments").select("id").eq("square_payment_id", payment.id).maybeSingle();
      if (!existing) throw insertError;
    }

    const { error: updateError } = await db.from("dv_agent_invoice_square_sessions").update({
      status: "PAID", square_payment_id: payment.id, paid_at: payment.updated_at || payment.created_at || new Date().toISOString()
    }).eq("id", session.id).eq("status", "PENDING");
    if (updateError) throw updateError;
    return json({ ok: true, recorded: !insertError });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Webhook processing failed." }, 500);
  }
});