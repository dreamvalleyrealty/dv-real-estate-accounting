import React, { useEffect, useState } from "react";
import { supabase } from "./lib/supabase";
import OpenHouseSigns from "./OpenHouseSigns";
import { Camera, LogOut, MapPin, ShieldCheck } from "lucide-react";

const ADMIN_ROLES = ["SUPERADMIN","ADMIN","MANAGER","BROKER","BROKER_OF_RECORD","BROKER OF RECORD","OWNER"];

export default function FieldApp() {
  const [user, setUser] = useState(null);
  const [profile, setProfile] = useState(null);
  const [agentId, setAgentId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!supabase) { setError("The app is not connected to the Back Office database."); setLoading(false); return; }
    let alive = true;
    supabase.auth.getSession().then(({data}) => { if (alive) setUser(data.session?.user || null); });
    const {data:{subscription}} = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user || null);
      setProfile(null);
      setAgentId(null);
    });
    return () => { alive = false; subscription.unsubscribe(); };
  }, []);

  useEffect(() => {
    if (!user?.id || !supabase) { setProfile(null); setAgentId(null); setLoading(false); return; }
    let cancelled = false;
    setLoading(true); setError("");
    (async () => {
      const {data: p, error: profileError} = await supabase.from("dv_accounting_user_profiles")
        .select("company_id,display_name,role,active").eq("user_id", user.id).maybeSingle();
      if (profileError) throw profileError;
      if (p?.active === false) throw new Error("Your Back Office account is inactive. Contact your administrator.");
      const role = String(p?.role || user.app_metadata?.role || user.user_metadata?.role || "").toUpperCase();
      let linkedAgentId = null;
      if (user.email) {
        let q = supabase.from("dv_accounting_agents").select("id").ilike("email", user.email).limit(1);
        if (p?.company_id) q = q.eq("company_id", p.company_id);
        const {data: agent, error: agentError} = await q.maybeSingle();
        if (agentError && agentError.code !== "PGRST116") throw agentError;
        linkedAgentId = agent?.id || null;
      }
      if (!ADMIN_ROLES.includes(role) && !linkedAgentId) {
        throw new Error("Your login is not linked to an agent profile yet. Please ask the Back Office administrator to link your account.");
      }
      if (cancelled) return;
      setProfile({...p, role, display_name:p?.display_name || user.user_metadata?.display_name || user.email});
      setAgentId(linkedAgentId);
    })().catch(e => { if (!cancelled) setError(e.message || "Could not load your account."); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [user?.id]);

  async function signIn(e) {
    e.preventDefault(); setBusy(true); setError("");
    const {error: authError} = await supabase.auth.signInWithPassword({email:email.trim(), password});
    if (authError) setError(authError.message);
    setBusy(false);
  }

  async function signOut() {
    await supabase.auth.signOut();
    setProfile(null); setAgentId(null);
  }

  if (!user) return <main className="field-auth">
    <div className="field-login-card">
      <img className="field-login-logo" src="/dv-logo.svg" alt="Dream Valley Realty"/>
      <p className="field-kicker">DREAM VALLEY REALTY</p>
      <h1>Open House Signs</h1>
      <p className="field-subtitle">Plan your signs. Take photos. Keep everything in sync.</p>
      <form onSubmit={signIn}>
        <label>Email address<input type="email" autoComplete="username" required value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@example.com"/></label>
        <label>Password<input type="password" autoComplete="current-password" required value={password} onChange={e=>setPassword(e.target.value)} placeholder="Your Back Office password"/></label>
        {error && <div className="field-error">{error}</div>}
        <button className="field-submit" disabled={busy}>{busy ? "Signing in…" : "Sign in"}</button>
      </form>
      <small>Use your existing Dream Valley Back Office login.</small>
    </div>
  </main>;

  const isAdmin = ADMIN_ROLES.includes(String(profile?.role || "").toUpperCase());
  return <div className="field-shell">
    <header className="field-topbar">
      <div className="field-brand"><img className="field-brand-logo" src="/dv-logo.svg" alt="Dream Valley Realty"/><div><strong>Dream Valley</strong><small>OPEN HOUSE SIGNS</small></div></div>
      <button className="field-signout" onClick={signOut} aria-label="Sign out"><LogOut size={18}/></button>
    </header>
    {loading ? <div className="field-loading">Preparing your sign workspace…</div> : error ? <div className="field-message"><ShieldCheck/><h2>Account setup needed</h2><p>{error}</p><button onClick={signOut}>Sign out</button></div> :
      <div className="field-content">
        <div className="field-welcome"><div><span>FIELD TOOLS</span><h1>Open House Signs</h1><p>Hi {profile?.display_name?.split(" ")[0] || "there"}, ready to plan?</p></div><div className="field-hero-icon"><MapPin/></div></div>
        <OpenHouseSigns user={user} agentId={agentId} role={profile?.role || "AGENT"} adminMode={isAdmin}/>
      </div>}
    <nav className="field-bottom"><span><MapPin size={16}/> Plan</span><span><Camera size={16}/> Install</span><small>Synced with DV Back Office</small></nav>
  </div>;
}