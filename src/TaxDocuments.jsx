import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,FileText,Lock,AlertTriangle} from "lucide-react";

const money=value=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(value||0));
export default function TaxDocuments({agentId}){
 const [year,setYear]=useState(new Date().getFullYear()-1),[slips,setSlips]=useState([]),[busy,setBusy]=useState(false),[error,setError]=useState("");
 const load=useCallback(async()=>{
  if(!supabase||!agentId){setSlips([]);return}
  setBusy(true);setError("");
  try{
   const {data,error}=await supabase.from("dv_accounting_tax_slips").select("id,tax_year,slip_type,status,recipient_name,boxes,updated_at").eq("agent_id",agentId).eq("slip_type","T4A").eq("tax_year",Number(year)).eq("status","released").order("tax_year",{ascending:false});
   if(error)throw error;setSlips(data||[]);
  }catch(e){setError(e?.message||"Could not load your tax documents.");setSlips([])}
  finally{setBusy(false)}
 },[agentId,year]);
 useEffect(()=>{load()},[load]);
 return <div className="page">
  <div className="pagehead"><div><h1>Tax Documents</h1><p className="muted">Access your released T4A tax slips from Dream Valley Realty.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
  <section className="panel">
   <label>Tax year<select value={year} onChange={e=>setYear(Number(e.target.value))} style={{display:"block",padding:9,minWidth:150,marginTop:6}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label>
   {error&&<p role="alert" style={{color:"#b91c1c",marginTop:12}}>{error}</p>}
   <div style={{display:"flex",gap:10,alignItems:"start",marginTop:18,padding:14,background:"#fff8e8",borderRadius:8}}><AlertTriangle size={19}/><div><strong>Tax slip information</strong><p className="muted" style={{margin:"6px 0 0"}}>Values entered by the brokerage are shown below. Please contact the brokerage if any recipient details or box values need correction. Official PDF printing is not enabled yet.</p></div></div>
   {slips.length?<div style={{marginTop:18,display:"grid",gap:12}}>{slips.map(slip=>{const boxes=slip.boxes||{};const amount=boxes.manual_reportable_amount;const entries=Object.entries(boxes).filter(([key,value])=>key!=="manual_reportable_amount"&&value!==null&&value!=="");return <div key={slip.id} style={{border:"1px solid #e4e7ec",borderRadius:10,padding:16}}><div style={{display:"flex",justifyContent:"space-between",alignItems:"start",gap:12,flexWrap:"wrap"}}><div><strong><FileText size={17} style={{verticalAlign:"middle",marginRight:8}}/>T4A — {slip.tax_year}</strong><div className="muted" style={{marginTop:6}}>Status: Released{slip.updated_at?" · Updated "+new Date(slip.updated_at).toLocaleDateString():""}</div><div style={{marginTop:8}}>Manual reportable amount: {amount===undefined||amount===null||amount===""?"Not entered":money(amount)}</div></div><button className="secondary" disabled title="PDF printing will be enabled in a later phase"><Lock size={15}/> PDF unavailable</button></div>{entries.length>0&&<div style={{marginTop:14,overflowX:"auto"}}><table className="table"><thead><tr><th>CRA box / field</th><th>Value</th></tr></thead><tbody>{entries.map(([key,value])=><tr key={key}><td>{key}</td><td>{typeof value==="object"?JSON.stringify(value):String(value)}</td></tr>)}</tbody></table></div>}</div>})}</div>
    :<div style={{padding:"28px 12px",textAlign:"center"}}><FileText size={30} style={{opacity:.55}}/><h3 style={{margin:"10px 0 6px"}}>{busy?"Loading tax documents…":"No released T4A for "+year}</h3><p className="muted" style={{margin:0}}>When your T4A is reviewed and released by the brokerage, it will be listed here.</p></div>}
   <p className="muted" style={{marginTop:14,fontSize:13}}><Lock size={14} style={{verticalAlign:"middle",marginRight:5}}/>Only released slips linked to your agent account can be displayed. PDF printing remains unavailable.</p>
  </section>
 </div>
}
