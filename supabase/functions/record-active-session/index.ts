import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("APP_ORIGIN") || "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getClientIp(req: Request): string | null {
  // These headers are supplied by the hosting proxy, not by the browser payload.
  const forwarded = req.headers.get("x-forwarded-for");
  const candidate = forwarded?.split(",")[0]?.trim()
    || req.headers.get("cf-connecting-ip")?.trim()
    || req.headers.get("x-real-ip")?.trim()
    || "";
  const ip = candidate.replace(/^\[|\]$/g, "").replace(/^::ffff:/i, "");
  if (!ip || ip.length > 64) return null;
  // Reject values that are not valid IPv4 or IPv6 literals.
  const ipv4 = /^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip)
    && ip.split(".").every((part) => Number(part) >= 0 && Number(part) <= 255);
  const ipv6 = /^[0-9a-f:]+$/i.test(ip) && ip.includes(":");
  return ipv4 || ipv6 ? ip : null;
}

function isPublicIp(ip: string): boolean {
  if (ip.includes(":")) {
    const value = ip.toLowerCase();
    return value !== "::1" && !value.startsWith("fc") && !value.startsWith("fd")
      && !value.startsWith("fe80:") && value !== "::";
  }
  const [a, b] = ip.split(".").map(Number);
  return a !== 10 && a !== 127 && !(a === 192 && b === 168)
    && !(a === 172 && b >= 16 && b <= 31)
    && !(a === 169 && b === 254) && a !== 0
    && a < 224;
}

async function lookupLocation(ip: string): Promise<string | null> {
  if (!isPublicIp(ip)) return null;
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3500);
    const result = await fetch(`https://ipwho.is/${encodeURIComponent(ip)}`, {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    clearTimeout(timeout);
    if (!result.ok) return null;
    const data = await result.json();
    if (data?.success === false) return null;
    const parts = [data?.city, data?.region, data?.country]
      .map((value) => typeof value === "string" ? value.trim() : "")
      .filter(Boolean);
    return parts.length ? [...new Set(parts)].join(", ").slice(0, 180) : null;
  } catch (error) {
    console.warn("IP geolocation lookup failed:", error instanceof Error ? error.message : "Unknown error");
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response({ error: "Method not allowed." }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const authorization = req.headers.get("Authorization") || "";
    const token = authorization.replace(/^Bearer\s+/i, "");
    if (!url || !anonKey) return response({ error: "Server configuration is incomplete." }, 500);
    if (!token) return response({ error: "Authentication is required." }, 401);

    const client = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await client.auth.getUser(token);
    const authUser = authData?.user;
    if (authError || !authUser) return response({ error: "The session could not be verified." }, 401);

    let payload: Record<string, unknown>;
    try { payload = await req.json(); } catch { return response({ error: "Invalid request body." }, 400); }
    const sessionId = typeof payload.session_id === "string" ? payload.session_id.trim() : "";
    const userAgent = typeof payload.user_agent === "string" ? payload.user_agent.slice(0, 240) : "";
    if (!sessionId || sessionId.length > 160) return response({ error: "A valid session ID is required." }, 400);

    const { data: profile, error: profileError } = await client
      .from("dv_accounting_user_profiles")
      .select("display_name,role")
      .eq("user_id", authUser.id)
      .maybeSingle();
    if (profileError) throw profileError;

    const { data: existing, error: existingError } = await client
      .from("dv_accounting_active_sessions")
      .select("ip_address,ip_location,ip_lookup_at")
      .eq("session_id", sessionId)
      .eq("user_id", authUser.id)
      .maybeSingle();
    if (existingError) throw existingError;

    const observedIp = getClientIp(req);
    let ipAddress = existing?.ip_address || null;
    let ipLocation = existing?.ip_location || null;
    let ipLookupAt = existing?.ip_lookup_at || null;
    if (observedIp && observedIp !== existing?.ip_address) {
      ipAddress = observedIp;
      ipLocation = await lookupLocation(observedIp);
      ipLookupAt = new Date().toISOString();
    }

    const { error: saveError } = await client.from("dv_accounting_active_sessions").upsert({
      session_id: sessionId,
      user_id: authUser.id,
      email: authUser.email || null,
      display_name: profile?.display_name || authUser.email || "User",
      role: profile?.role || authUser.app_metadata?.role || "STAFF",
      last_seen_at: new Date().toISOString(),
      user_agent: userAgent || null,
      ip_address: ipAddress,
      ip_location: ipLocation,
      ip_lookup_at: ipLookupAt,
    }, { onConflict: "session_id" });
    if (saveError) throw saveError;

    return response({ success: true, ip_captured: Boolean(ipAddress), location_available: Boolean(ipLocation) });
  } catch (error) {
    console.error("Session tracking failed:", error instanceof Error ? error.message : "Unknown error");
    return response({ error: "Could not update the tracked session." }, 500);
  }
});
