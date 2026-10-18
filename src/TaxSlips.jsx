import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {Printer,RefreshCw,Plus,Lock,AlertTriangle,Save,Edit2,X} from "lucide-react";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const recipientName=person=>String(person?.legal_name||person?.name||[person?.first_name,person?.last_name].filter(Boolean).join(" ")||"").trim();
const pretty=value=>JSON.stringify(value&&typeof value==="object"?value:{},null,2);

export default function TaxSlips({user,role="STAFF"}){
 const admin=["SUPERADMIN","ADMIN","BROKER_OF_RECORD"].includes(String(role).toUpperCase());
 const [year,setYear]=useState(new Date().getFullYear()-1),[kind,setKind]=useState("T4A"),[rows,setRows]=useState([]),[busy,setBusy]=useState(false),[error,setError]=useState(""),[note,setNote]=useState("");
 const [editing,setEditing]=useState(null),[editName,setEditName]=useState(""),[editEmail,setEditEmail]=useState(""),[editStatus,setEditStatus]=useState("draft"),[editBoxes,setEditBoxes]=useState("{}"),[editNotes,setEditNotes]=useState("");

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
    const{error}=await supabase.from("dv_accounting_tax_years").insert({tax_year:taxYear,status:"setup",t4_enabled:true,t4a_enabled:true,created_by:user?.id||null,updated_by:user?.id||null});
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
    tax_year:taxYear,slip_type:kind,agent_id:kind==="T4A"?person.id:null,employee_id:kind==="T4"?person.id:null,
    recipient_user_id:person.user_id||null,recipient_name:recipientName(person)||"Unassigned recipient",
    recipient_email:person.email||null,status:"draft",boxes:{},source_summary:{source:"manual_entry",amounts_calculated:false},
    created_by:user?.id||null,updated_at:new Date().toISOString()
   }));
   if(missing.length){const{error:insertError}=await supabase.from("dv_accounting_tax_slips").insert(missing);if(insertError)throw insertError}
   setNote("Setup complete: "+missing.length+" new draft "+kind+" slip"+(missing.length===1?"":"s")+" added. Existing records were preserved. Open any draft below to enter the slip information manually.");
   await load();
  }catch(e){setError(e?.message||"Could not set up the tax year and draft slips.")}
  finally{setBusy(false)}
 };

 const startEdit=row=>{
  setEditing(row.id);setEditName(row.recipient_name||"");setEditEmail(row.recipient_email||"");
  setEditStatus(row.status||"draft");setEditBoxes(pretty(row.boxes));setEditNotes(row.notes||"");setError("");setNote("");
 };
 const saveEdit=async()=>{
  if(!admin||!editing||!supabase)return;
  setBusy(true);setError("");setNote("");
  try{
   let boxes;try{boxes=JSON.parse(editBoxes||"{}")}catch{throw new Error("CRA box data must be valid JSON.")}
   if(!boxes||typeof boxes!=="object"||Array.isArray(boxes))throw new Error("CRA box data must be a JSON object, for example { \"48\": 1250.00 }.");
   const changes={recipient_name:editName.trim()||"Unassigned recipient",recipient_email:editEmail.trim()||null,status:editStatus,boxes,notes:editNotes.trim()||null,updated_at:new Date().toISOString()};
   if(editStatus==="released"){changes.released_at=new Date().toISOString();changes.released_by=user?.id||null}
   else {changes.released_at=null;changes.released_by=null}
   const{error}=await supabase.from("dv_accounting_tax_slips").update(changes).eq("id",editing);
   if(error)throw error;
   setNote(editStatus==="released"?"Slip saved and marked released. Confirm all recipient details and CRA boxes before releasing.":"Manual slip information saved.");
   setEditing(null);await load();
  }catch(e){setError(e?.message||"Could not save this slip.")}
  finally{setBusy(false)}
 };
 const print=()=>window.print();
 const amountFor=row=>{
  const boxes=row.boxes||{};
  const value=boxes.manual_reportable_amount;
  return value===undefined||value===null||value===""?null:Number(value);
 };
 return <div className="page"><div className="pagehead"><div><h1>Tax Slips</h1><p className="muted">Manually prepare annual T4 slips for employees and T4A slips for agents.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
 <section className="panel"><div style={{display:"flex",gap:12,alignItems:"end",flexWrap:"wrap"}}><label>Tax year<select value={year} onChange={e=>{setYear(Number(e.target.value));setNote("");setError("");setEditing(null)}} style={{display:"block",padding:9,minWidth:130}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label><label>Slip type<select value={kind} onChange={e=>{setKind(e.target.value);setNote("");setError("");setEditing(null)}} style={{display:"block",padding:9,minWidth:180}}><option value="T4A">T4A — Agents / contractors</option><option value="T4">T4 — Employees</option></select></label>{admin&&<button className="primary" onClick={addDraft} disabled={busy}><Plus size={15}/> {busy?"Setting up…":"Add missing recipient drafts"}</button>}<button className="secondary" onClick={print}><Printer size={15}/> Print list</button></div>
 {error&&<p role="alert" style={{color:"#b91c1c",marginTop:12}}>{error}</p>}{note&&<p role="status" style={{marginTop:12}}>{note}</p>}
 <div style={{display:"flex",gap:10,alignItems:"start",marginTop:18,padding:12,background:"#fff8e8",borderRadius:8}}><AlertTriangle size={18}/><div><strong>Manual entry mode</strong><div className="muted">You can enter recipient details, CRA box values, notes, and status manually. Enter the official CRA box numbers and values as a JSON object. Optional field <code>manual_reportable_amount</code> is only a convenience for the list display; it is not a substitute for completing the required CRA boxes. Verify each slip against CRA requirements before releasing or filing.</div></div></div>
 <div style={{overflowX:"auto",marginTop:16}}><table className="table"><thead><tr><th>Recipient</th><th>Slip</th><th>Status</th><th>Manual reportable amount</th><th>Updated</th>{admin&&<th>Action</th>}</tr></thead><tbody>{rows.length?rows.map(row=><tr key={row.id}><td>{row.recipient_name||"Unassigned"}<div className="muted">{row.recipient_email||""}</div></td><td>{row.slip_type}</td><td>{row.status||"draft"}</td><td>{amountFor(row)==null||!Number.isFinite(amountFor(row))?"—":money(amountFor(row))}</td><td>{row.updated_at?new Date(row.updated_at).toLocaleDateString():"—"}</td>{admin&&<td><button className="secondary" onClick={()=>startEdit(row)}><Edit2 size={14}/> Edit</button></td>}</tr>):<tr><td colSpan={admin?6:5} className="muted">{busy?"Loading tax slips…":"No slip records exist for this year and type yet. Use Add missing recipient drafts to create them."}</td></tr>}</tbody></table></div>
 {editing&&<div style={{marginTop:20,border:"1px solid #d0d5dd",borderRadius:10,padding:16}}><div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:8}}><h3 style={{margin:0}}>Edit {kind} slip</h3><button className="secondary" onClick={()=>setEditing(null)} disabled={busy}><X size={15}/> Cancel</button></div>
 <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(220px,1fr))",gap:12,marginTop:14}}><label>Recipient legal name<input value={editName} onChange={e=>setEditName(e.target.value)} style={{display:"block",width:"100%",padding:9,marginTop:5}}/></label><label>Recipient email<input type="email" value={editEmail} onChange={e=>setEditEmail(e.target.value)} style={{display:"block",width:"100%",padding:9,marginTop:5}}/></label><label>Status<select value={editStatus} onChange={e=>setEditStatus(e.target.value)} style={{display:"block",width:"100%",padding:9,marginTop:5}}><option value="draft">Draft</option><option value="review">Review</option><option value="released">Released — visible to agent</option><option value="cancelled">Cancelled</option></select></label></div>
 <label style={{display:"block",marginTop:14}}>CRA boxes — JSON object<textarea value={editBoxes} onChange={e=>setEditBoxes(e.target.value)} rows={10} spellCheck={false} style={{display:"block",width:"100%",padding:10,marginTop:5,fontFamily:"monospace"}} placeholder={'{\n  "48": 1250.00,\n  "manual_reportable_amount": 1250.00\n}'}/></label>
 <label style={{display:"block",marginTop:14}}>Internal notes<textarea value={editNotes} onChange={e=>setEditNotes(e.target.value)} rows={3} style={{display:"block",width:"100%",padding:10,marginTop:5}}/></label>
 <div style={{display:"flex",gap:10,justifyContent:"flex-end",marginTop:14}}><button className="secondary" onClick={()=>setEditing(null)} disabled={busy}>Cancel</button><button className="primary" onClick={saveEdit} disabled={busy}><Save size={15}/>{busy?" Saving…":" Save slip"}</button></div>
 </div>}
 {admin&&<p className="muted" style={{marginTop:14}}><Lock size={14} style={{verticalAlign:"middle"}}/> Admin-only editing. Releasing a slip makes it visible in the agent's Tax Documents page; the agent print/PDF function remains disabled.</p>}
 </section></div>
}
