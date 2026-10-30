import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const money = (n: number) => Math.round(n * 100) / 100;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authHeader = req.headers.get("Authorization") || "";
    const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user?.email) return json({ error: "Please sign in again." }, 401);
    const db = createClient(url, serviceKey);
    const { data: agent, error: agentError } = await db.from("dv_accounting_agents").select("id,name,email,branch_id,active").ilike("email", userData.user.email).eq("active", true).maybeSingle();
    if (agentError || !agent) return json({ error: "Your login is not linked to an active agent profile." }, 403);
    const body = await req.json();
    const action = body.action;
    if (action === "submit_interac_reference") {
      const orderId = String(body.order_id || "");
      const reference = String(body.interac_reference || "").trim();
      if (!orderId || !reference || reference.length > 120) return json({ error: "Enter a valid Interac e-Transfer reference code." }, 400);
      const { data: order, error: orderError } = await db.from("dv_accounting_inventory_orders")
        .select("id,order_number,payment_method,payment_status,interac_reference")
        .eq("id", orderId).eq("agent_id", agent.id).maybeSingle();
      if (orderError || !order) return json({ error: "Order not found." }, 404);
      if (order.payment_method !== "INTERAC" || order.payment_status !== "PENDING") return json({ error: "This order is not awaiting an Interac reference." }, 409);
      if (order.interac_reference) return json({ error: "An Interac reference has already been submitted. Contact the office if it needs correction." }, 409);
      const { error: updateError } = await db.from("dv_accounting_inventory_orders")
        .update({ interac_reference: reference, updated_at: new Date().toISOString() })
        .eq("id", order.id).is("interac_reference", null).eq("payment_status", "PENDING");
      if (updateError) throw updateError;
      return json({ ok: true, order_number: order.order_number, message: "Interac reference submitted. The office will verify the transfer." });
    }
    if (action === "cancel_interac_order") {
      const orderId = String(body.order_id || "");
      const { data: order, error: orderError } = await db.from("dv_accounting_inventory_orders")
        .select("id,order_number,payment_method,payment_status,interac_reference,order_status")
        .eq("id", orderId).eq("agent_id", agent.id).maybeSingle();
      if (orderError || !order) return json({ error: "Order not found." }, 404);
      if (order.payment_method !== "INTERAC" || order.payment_status !== "PENDING" || order.interac_reference || order.order_status === "FULFILLED") {
        return json({ error: "This order can no longer be cancelled online. Contact the office for assistance." }, 409);
      }
      const { error: cancelError } = await db.from("dv_accounting_inventory_orders")
        .update({ payment_status: "CANCELLED", order_status: "CANCELLED", updated_at: new Date().toISOString() })
        .eq("id", order.id).eq("payment_status", "PENDING").is("interac_reference", null);
      if (cancelError) throw cancelError;
      return json({ ok: true, order_number: order.order_number, message: "Order cancelled before Interac payment was sent." });
    }
    if (action === "request_borrow") {
      const lines = Array.isArray(body.items) ? body.items : [];
      if (!lines.length || lines.length > 30) return json({ error: "Choose at least one item." }, 400);
      const branchId = body.branch_id || agent.branch_id || null;
      const requested = new Map<string, number>();
      for (const line of lines) {
        const quantity = Number(line.quantity);
        if (!Number.isInteger(quantity) || quantity <= 0 || quantity > 100) return json({ error: "Borrowing quantities must be whole numbers between 1 and 100." }, 400);
        requested.set(String(line.item_id), (requested.get(String(line.item_id)) || 0) + quantity);
      }
      const itemRows: any[] = [];
      for (const [itemId, quantity] of requested) {
        const { data: item, error } = await db.from("dv_accounting_inventory_items")
          .select("id,item_name,item_type,is_active,stock_quantity")
          .eq("id", itemId).single();
        if (error || !item || item.item_type !== "LOANABLE" || !item.is_active) return json({ error: "A selected item is not available to borrow." }, 400);
        let onHand = Number(item.stock_quantity || 0);
        if (branchId) {
          const { data: branchStock } = await db.from("dv_accounting_inventory_branch_stock")
            .select("quantity").eq("item_id", item.id).eq("branch_id", branchId).maybeSingle();
          if (branchStock) onHand = Number(branchStock.quantity || 0);
        }
        const { data: approvedRows, error: reservedError } = await db.from("dv_accounting_inventory_borrow_requests")
          .select("id,items:dv_accounting_inventory_borrow_request_items!inner(quantity,item_id)")
          .eq("branch_id", branchId).eq("status", "APPROVED")
          .eq("items.item_id", item.id);
        if (reservedError) throw reservedError;
        const reserved = (approvedRows || []).reduce((sum: number, row: any) =>
          sum + (row.items || []).reduce((n: number, x: any) => n + Number(x.quantity || 0), 0), 0);
        const available = Math.max(0, onHand - reserved);
        if (quantity > available) return json({ error: item.item_name + " has only " + available + " available to borrow at this branch. Approved requests are reserved." }, 409);
        itemRows.push({ item_id: item.id, item_name: item.item_name, quantity });
      }
      const { data: request, error: insertError } = await db.from("dv_accounting_inventory_borrow_requests").insert({
        request_number: "BR-" + crypto.randomUUID().slice(0, 8).toUpperCase(),
        agent_id: agent.id, branch_id: branchId, pickup_date: body.pickup_date || null,
        due_date: body.due_date || null, notes: String(body.notes || "").slice(0, 1000), status: "PENDING"
      }).select().single();
      if (insertError) throw insertError;
      const { error: linesError } = await db.from("dv_accounting_inventory_borrow_request_items")
        .insert(itemRows.map(x => ({ ...x, request_id: request.id })));
      if (linesError) throw linesError;
      return json({ ok: true, request });
    }
    if (action !== "create_order") return json({ error: "Unknown action." }, 400);
    const lines = Array.isArray(body.items) ? body.items : [];
    if (!lines.length || lines.length > 30) return json({ error: "Your cart is empty or too large." }, 400);
    const method = body.payment_method === "INTERAC" ? "INTERAC" : "SQUARE";
    const branchId = body.branch_id || agent.branch_id || null;
    let subtotal = 0, hst = 0;
    const snapshots = [];
    for (const line of lines) {
      const quantity = Number(line.quantity);
      if (!Number.isFinite(quantity) || quantity <= 0 || quantity > 100) return json({ error: "Invalid quantity." }, 400);
      const { data: item, error } = await db.from("dv_accounting_inventory_items").select("id,item_code,item_name,item_type,description,sale_price,tax_rate,is_active,stock_quantity,image_url").eq("id", line.item_id).single();
      if (error || !item || !item.is_active || !["SELLABLE","SERVICE","GIFT"].includes(item.item_type)) return json({ error: "A selected product is no longer available." }, 400);
      if (item.item_type !== "SERVICE") {
        let available = Number(item.stock_quantity || 0);
        if (branchId) {
          const { data: stock } = await db.from("dv_accounting_inventory_branch_stock").select("quantity").eq("item_id", item.id).eq("branch_id", branchId).maybeSingle();
          if (stock) available = Number(stock.quantity || 0);
        }
        if (quantity > available) return json({ error: item.item_name + " has only " + available + " available at this branch." }, 409);
      }
      const price = Number(item.sale_price || 0), rate = Number(item.tax_rate || 0);
      const lineSubtotal = money(price * quantity), lineTax = money(lineSubtotal * rate / 100);
      subtotal += lineSubtotal; hst += lineTax;
      snapshots.push({ item_id: item.id, item_name: item.item_name, item_code: item.item_code, quantity, unit_price: price, tax_rate: rate, subtotal: lineSubtotal, hst_amount: lineTax, total_amount: money(lineSubtotal + lineTax) });
    }
    subtotal = money(subtotal); hst = money(hst);
    const total = money(subtotal + hst);
    const orderNumber = "DV-" + new Date().toISOString().slice(0,10).replaceAll("-","") + "-" + crypto.randomUUID().slice(0,6).toUpperCase();
    const { data: order, error: orderError } = await db.from("dv_accounting_inventory_orders").insert({
      order_number: orderNumber, agent_id: agent.id, branch_id: branchId, payment_method: method,
      payment_status: "PENDING", order_status: "PENDING", subtotal, hst_amount: hst, total_amount: total,
      payment_reference: method === "INTERAC" ? orderNumber : null, notes: String(body.notes || "").slice(0,1000)
    }).select().single();
    if (orderError) throw orderError;
    const { error: lineError } = await db.from("dv_accounting_inventory_order_items").insert(snapshots.map(x => ({ ...x, order_id: order.id })));
    if (lineError) throw lineError;
    if (method === "INTERAC") return json({ ok: true, order, payment_email: "admin@dvrealty.ca" });
    const token = Deno.env.get("SQUARE_ACCESS_TOKEN");
    const locationId = Deno.env.get("SQUARE_LOCATION_ID");
    if (!token || !locationId) throw new Error("Square Sandbox credentials are not configured.");
    const origin = new URL(req.headers.get("origin") || "https://localhost").origin;
    const squareResponse = await fetch("https://connect.squareupsandbox.com/v2/online-checkout/payment-links", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json", "Square-Version": "2025-10-16" },
      body: JSON.stringify({
        idempotency_key: crypto.randomUUID(),
        order: {
          location_id: locationId,
          reference_id: orderNumber,
          line_items: snapshots.map(x => ({
            name: x.item_name, quantity: String(x.quantity),
            base_price_money: { amount: Math.round(x.unit_price * 100), currency: "CAD" },
            ...(x.tax_rate > 0 ? { applied_taxes: [{ tax_uid: "hst-" + x.item_id }] } : {})
          })),
          taxes: snapshots
            .filter(x => x.tax_rate > 0)
            .map(x => ({
              uid: "hst-" + x.item_id,
              name: "HST",
              percentage: String(x.tax_rate),
              scope: "LINE_ITEM"
            }))
        },
        checkout_options: { redirect_url: origin + "?inventory_order=" + encodeURIComponent(orderNumber), merchant_support_email: "admin@dvrealty.ca" },
        pre_populated_data: { buyer_email: userData.user.email }
      })
    });
    const squareData = await squareResponse.json();
    if (!squareResponse.ok || !squareData.payment_link?.url) {
      const squareErrors = Array.isArray(squareData.errors)
        ? squareData.errors.map((e: any) => ({
            category: e.category || null,
            code: e.code || null,
            detail: e.detail || null,
            field: e.field || null,
          }))
        : [];
      const detail = squareErrors.find((e: any) => e.detail)?.detail
        || "Square could not create the checkout link.";
      console.error("Square payment link creation failed", JSON.stringify({
        http_status: squareResponse.status,
        order_number: orderNumber,
        errors: squareErrors,
      }));
      await db.from("dv_accounting_inventory_orders")
        .update({ payment_status: "FAILED" }).eq("id", order.id);
      return json({
        error: detail,
        square: { http_status: squareResponse.status, errors: squareErrors },
      }, 502);
    }
    await db.from("dv_accounting_inventory_orders").update({
      square_payment_link_id: squareData.payment_link.id,
      square_order_id: squareData.payment_link.order_id,
      checkout_url: squareData.payment_link.url
    }).eq("id", order.id);
    return json({ ok: true, order, checkout_url: squareData.payment_link.url });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Request failed." }, 400);
  }
});