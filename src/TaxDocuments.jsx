import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,FileText,Lock,AlertTriangle} from "lucide-react";

const money=value=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(value||0));

export default function TaxDocuments({agentId}){
 const [year,setYear]=useState(new Date().getFullYear()-1);
 const [slips,setSlips]=useState([]);
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState("");
 const load=useCallback(async()=>{
  if(!supabase||!agentId){setSlips([]);return}
  setBusy(true);setError("");
  try{
   // RLS permits recipients to read only released slips linked to their own account.
   const {data,error}=await supabase.from("dv_accounting_tax_slips")
    .select("id,tax_year,slip_type,status,recipient_name,reportable_amount,updated_at")
    .eq("agent_id",agentId).eq("slip_type","T4A").eq("tax_year",Number(year))
    .eq("status","released").order("tax_year",{ascending:false});
   if(error)throw error;
   setSlips(data||[]);
  }catch(e){setError(e?.message||"Could not load your tax documents.");setSlips([])}
  finally{setBusy(false)}
 },[agentId,year]);
 useEffect(()=>{load()},[load]);
 return <div className="page">
  <div className="pagehead"><div><h1>Tax Documents</h1><p className="muted">Access your released T4A tax slips from Dream Valley Realty.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
  <section className="panel">
   <label>Tax year<select value={year} onChange={e=>setYear(Number(e.target.value))} style={{display:"block",padding:9,minWidth:150,marginTop:6}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label>
   {error&&<p role="alert" style={{color:"#b91c1c",marginTop:12}}>{error}</p>}
   <div style={{display:"flex",gap:10,alignItems:"start",marginTop:18,padding:14,background:"#fff8e8",borderRadius:8}}>
    <AlertTriangle size={19}/><div><strong>T4A self-service is being prepared</strong><p className="muted" style={{margin:"6px 0 0"}}>Your T4A will appear here after the brokerage validates the payment totals and recipient information and releases the slip. Draft slips are not shown to agents.</p></div>
   </div>
   {slips.length? <div style={{marginTop:18,display:"grid",gap:12}}>{slips.map(slip=><div key={slip.id} style={{border:"1px solid #e4e7ec",borderRadius:10,padding:16,display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap"}}><div><strong><FileText size={17} style={{verticalAlign:"middle",marginRight:8}}/>T4A — {slip.tax_year}</strong><div className="muted" style={{marginTop:6}}>Status: Released{slip.updated_at?" · Updated "+new Date(slip.updated_at).toLocaleDateString():""}</div><div style={{marginTop:8}}>Reportable amount: {slip.reportable_amount==null?"Pending validation":money(slip.reportable_amount)}</div></div><button className="secondary" disabled title="Printing will be enabled after CRA form and amount validation"><Lock size={15}/> Print unavailable</button></div>)}</div>
    : <div style={{padding:"28px 12px",textAlign:"center"}}><FileText size={30} style={{opacity:.55}}/><h3 style={{margin:"10px 0 6px"}}>{busy?"Loading tax documents…":"No released T4A for "+year}</h3><p className="muted" style={{margin:0}}>When your T4A is reviewed and released by the brokerage, it will be listed here.</p></div>}
   <p className="muted" style={{marginTop:14,fontSize:13}}><Lock size={14} style={{verticalAlign:"middle",marginRight:5}}/>Only released slips linked to your agent account can be displayed. Printing remains disabled until the CRA form layout and payment calculations are validated.</p>
  </section>
 </div>
}
