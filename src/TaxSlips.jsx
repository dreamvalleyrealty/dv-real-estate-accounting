import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {Printer,RefreshCw,Plus,Lock,AlertTriangle} from "lucide-react";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const recipientName=person=>String(person?.legal_name||person?.name||[person?.first_name,person?.last_name].filter(Boolean).join(" ")||"").trim();

export default function TaxSlips({user,role="STAFF"}){
 const admin=["SUPERADMIN","ADMIN","BROKER_OF_RECORD"].includes(String(role).toUpperCase());
 const [year,setYear]=useState(new Date().getFullYear()-1),[kind,setKind]=useState("T4A"),[rows,setRows]=useState([]),[busy,setBusy]=useState(false),[error,setError]=useState(""),[note,setNote]=useState("");

 const load=useCallback(async()=>{
  if(!supabase){setRows([]);return}
  setBusy(true);setError("");
  try{
   const{data,error}=await supabase.from("dv_accounting_tax_slips").select("*").eq("tax_year",Number(year)).eq("slip_type",kind).order("recipient_name");
   if(error)throw error;
   setRows(data||[]);
  }catch(e){setError(e?.message||"Could not load tax slips.");setRows([])}
  finally{setBusy(false)}
 },[year,kind]);

 useEffect(()=>{load()},[load]);

 const addDraft=async()=>{
  if(!admin||!supabase)return;
  setBusy(true);setError("");setNote("");
  try{
   const taxYear=Number(year);
   const{data:existingYear,error:yearReadError}=await supabase.from("dv_accounting_tax_years").select("id,status").eq("tax_year",taxYear).maybeSingle();
   if(yearReadError)throw yearReadError;
   if(existingYear){
    const{error}=await supabase.from("dv_accounting_tax_years").update({updated_by:user?.id||null,updated_at:new Date().toISOString()}).eq("tax_year",taxYear);
    if(error)throw error;
   }else{
    const{error}=await supabase.from("dv_accounting_tax_years").insert({tax_year:taxYear,status:"SETUP",t4_enabled:true,t4a_enabled:true,created_by:user?.id||null,updated_by:user?.id||null});
    if(error)throw error;
   }

   const personTable=kind==="T4A"?"dv_accounting_agents":"dv_accounting_employees";
   const personColumns=kind==="T4A"?"id,name,first_name,last_name,legal_name,email,user_id,active":"id,name,email,user_id,active";
   const{data:people,error:peopleError}=await supabase.from(personTable).select(personColumns).eq("active",true);
   if(peopleError)throw peopleError;

   const{data:existingSlips,error:slipReadError}=await supabase.from("dv_accounting_tax_slips").select("agent_id,employee_id").eq("tax_year",taxYear).eq("slip_type",kind);
   if(slipReadError)throw slipReadError;
   const existingIds=new Set((existingSlips||[]).map(row=>kind==="T4A"?row.agent_id:row.employee_id).filter(Boolean));
   const missing=(people||[]).filter(person=>!existingIds.has(person.id)).map(person=>({
    tax_year:taxYear,
    slip_type:kind,
    agent_id:kind==="T4A"?person.id:null,
    employee_id:kind==="T4"?person.id:null,
    recipient_user_id:person.user_id||null,
    recipient_name:recipientName(person)||"Unassigned recipient",
    recipient_email:person.email||null,
    status:"draft",
    boxes:{},
    source_summary:{source:"initial_setup",amounts_calculated:false},
    created_by:user?.id||null,
    updated_at:new Date().toISOString()
   }));

   if(missing.length){
    const{error:insertError}=await supabase.from("dv_accounting_tax_slips").insert(missing);
    if(insertError)throw insertError;
   }
   setNote("Tax year "+taxYear+" setup is ready. "+missing.length+" draft "+kind+" slip"+(missing.length===1?"":"s")+" created for active "+(kind==="T4A"?"agents":"employees")+". Existing slip records were preserved. Payment totals are not connected yet, so no reportable amounts have been calculated.");
   await load();
  }catch(e){setError(e?.message||"Could not set up the tax year and draft slips.")}
  finally{setBusy(false)}
 };

 const print=()=>window.print();
 return <div className="page"><div className="pagehead"><div><h1>Tax Slips</h1><p className="muted">Annual T4 slips for employees and T4A slips for agents.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
 <section className="panel"><div style={{display:"flex",gap:12,alignItems:"end",flexWrap:"wrap"}}><label>Tax year<select value={year} onChange={e=>{setYear(Number(e.target.value));setNote("");setError("");}} style={{display:"block",padding:9,minWidth:130}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i-1).map(y=><option key={y} value={y}>{y}</option>)}</select></label><label>Slip type<select value={kind} onChange={e=>{setKind(e.target.value);setNote("");setError("");}} style={{display:"block",padding:9,minWidth:180}}><option value="T4A">T4A — Agents / contractors</option><option value="T4">T4 — Employees</option></select></label>{admin&&<button className="primary" onClick={addDraft} disabled={busy}><Plus size={15}/> {busy?"Setting up…":"Set up tax year"}</button>}<button className="secondary" onClick={print}><Printer size={15}/> Print list</button></div>
 {error&&<p role="alert" style={{color:"#b91c1c",marginTop:12}}>{error}</p>}{note&&<p role="status" style={{marginTop:12}}>{note}</p>}
 <div style={{display:"flex",gap:10,alignItems:"start",marginTop:18,padding:12,background:"#fff8e8",borderRadius:8}}><AlertTriangle size={18}/><div><strong>Not yet ready for CRA filing</strong><div className="muted">This phase creates the annual setup and one controlled draft slip per active recipient. Payment totals and required CRA boxes are not calculated yet. Do not treat draft records or printouts as official CRA slips until amounts, recipient identity, required boxes, and the CRA form layout have been validated.</div></div></div>
 <div style={{overflowX:"auto",marginTop:16}}><table className="table"><thead><tr><th>Recipient</th><th>Slip</th><th>Status</th><th>Gross / reportable amount</th><th>Updated</th></tr></thead><tbody>{rows.length?rows.map(row=><tr key={row.id}><td>{row.recipient_name||"Unassigned"}</td><td>{row.slip_type}</td><td>{row.status||"DRAFT"}</td><td>{row.reportable_amount==null?"—":money(row.reportable_amount)}</td><td>{row.updated_at?new Date(row.updated_at).toLocaleDateString():"—"}</td></tr>):<tr><td colSpan="5" className="muted">{busy?"Loading tax slips…":"No slip records exist for this year and type yet."}</td></tr>}</tbody></table></div>
 {admin&&<p className="muted" style={{marginTop:14}}><Lock size={14} style={{verticalAlign:"middle"}}/> Admin setup only. Slip release and recipient self-service printing remain disabled until payment mapping, access controls, and CRA form validation are complete.</p>}
 </section></div>
}
