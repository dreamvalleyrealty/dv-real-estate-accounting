import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,Plus,Upload,FileText,Trash2,Lock} from "lucide-react";

const recipientName=p=>String(p?.legal_name||p?.name||[p?.first_name,p?.last_name].filter(Boolean).join(" ")||"").trim();
const admins=["SUPERADMIN","ADMIN","BROKER_OF_RECORD"];
export default function TaxSlips({user,role="STAFF"}){
 const admin=admins.includes(String(role).toUpperCase());
 const [year,setYear]=useState(new Date().getFullYear()-1),[kind,setKind]=useState("T4A"),[rows,setRows]=useState([]),[people,setPeople]=useState([]),[busy,setBusy]=useState(false),[error,setError]=useState(""),[note,setNote]=useState("");
 const load=useCallback(async()=>{
  if(!supabase)return;setBusy(true);setError("");
  try{const {data,error}=await supabase.from("dv_accounting_tax_slips").select("*").eq("tax_year",Number(year)).eq("slip_type",kind).order("recipient_name");if(error)throw error;setRows(data||[])}
  catch(e){setError(e?.message||"Could not load tax documents.");setRows([])}finally{setBusy(false)}
 },[year,kind]);
 useEffect(()=>{load()},[load]);
 const addDrafts=async()=>{
  if(!admin||!supabase)return;setBusy(true);setError("");setNote("");
  try{
   const table=kind==="T4A"?"dv_accounting_agents":"dv_accounting_employees";
   const cols=kind==="T4A"?"id,name,first_name,last_name,legal_name,email,user_id,active":"id,name,email,user_id,active";
   const {data:persons,error:pe}=await supabase.from(table).select(cols).eq("active",true);if(pe)throw pe;
   const {data:existing,error:ee}=await supabase.from("dv_accounting_tax_slips").select("agent_id,employee_id").eq("tax_year",Number(year)).eq("slip_type",kind);if(ee)throw ee;
   const ids=new Set((existing||[]).map(r=>kind==="T4A"?r.agent_id:r.employee_id).filter(Boolean));
   const missing=(persons||[]).filter(p=>!ids.has(p.id)).map(p=>({tax_year:Number(year),slip_type:kind,agent_id:kind==="T4A"?p.id:null,employee_id:kind==="T4"?p.id:null,recipient_user_id:p.user_id||null,recipient_name:recipientName(p)||"Unassigned recipient",recipient_email:p.email||null,status:"draft",boxes:{},source_summary:{source:"manual_pdf_upload"},created_by:user?.id||null}));
   if(missing.length){const {error:ie}=await supabase.from("dv_accounting_tax_slips").insert(missing);if(ie)throw ie}
   setNote("Added "+missing.length+" recipient draft(s). Upload a PDF beside each recipient, then release it for portal download.");await load();
  }catch(e){setError(e?.message||"Could not add recipient drafts.")}finally{setBusy(false)}
 };
 const upload=async(row,file)=>{
  if(!file||!admin||!supabase)return;
  if(file.type!=="application/pdf"&&!file.name.toLowerCase().endsWith(".pdf")){setError("Please select a PDF file.");return}
  if(file.size>15*1024*1024){setError("PDF must be 15 MB or smaller.");return}
  setBusy(true);setError("");setNote("");
  try{
   const path=String(year)+"/"+kind+"/"+row.id+".pdf";
   const {error:up}=await supabase.storage.from("dv-tax-slips").upload(path,file,{upsert:true,contentType:"application/pdf"});if(up)throw up;
   const {error:db}=await supabase.from("dv_accounting_tax_slips").update({storage_path:path,original_filename:file.name,mime_type:"application/pdf",file_size_bytes:file.size,status:"released",released_at:new Date().toISOString(),released_by:user?.id||null,updated_at:new Date().toISOString()}).eq("id",row.id);if(db)throw db;
   setNote(file.name+" uploaded and released for the assigned recipient.");await load();
  }catch(e){setError(e?.message||"Could not upload this PDF.")}finally{setBusy(false)}
 };
 const remove=async row=>{
  if(!admin||!supabase||!row.storage_path)return;
  if(!window.confirm("Remove the uploaded PDF for "+(row.recipient_name||"this recipient")+"?"))return;
  setBusy(true);setError("");setNote("");
  try{const {error:se}=await supabase.storage.from("dv-tax-slips").remove([row.storage_path]);if(se)throw se;
   const {error:de}=await supabase.from("dv_accounting_tax_slips").update({storage_path:null,original_filename:null,mime_type:null,file_size_bytes:null,status:"draft",released_at:null,released_by:null,updated_at:new Date().toISOString()}).eq("id",row.id);if(de)throw de;
   setNote("Uploaded document removed.");await load();
  }catch(e){setError(e?.message||"Could not remove the PDF.")}finally{setBusy(false)}
 };
 return <div className="page"><div className="pagehead"><div><h1>Tax Documents</h1><p className="muted">Upload prepared T4 and T4A PDFs. Recipients can download documents released to their portal.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
 <section className="panel"><div style={{display:"flex",gap:12,alignItems:"end",flexWrap:"wrap"}}><label>Tax year<select value={year} onChange={e=>{setYear(Number(e.target.value));setNote("");setError("")}} style={{display:"block",padding:9,minWidth:130}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label><label>Document type<select value={kind} onChange={e=>{setKind(e.target.value);setNote("");setError("")}} style={{display:"block",padding:9,minWidth:200}}><option value="T4A">T4A — Agents / contractors</option><option value="T4">T4 — Employees</option></select></label>{admin&&<button className="primary" onClick={addDrafts} disabled={busy}><Plus size={15}/> Add missing recipients</button>}</div>
 {error&&<p role="alert" style={{color:"#b42318",marginTop:12}}>{error}</p>}{note&&<p role="status" style={{marginTop:12}}>{note}</p>}
 <div style={{marginTop:16,padding:12,background:"#f8f6f0",borderRadius:8}}><strong>Manual PDF uploads</strong><p className="muted" style={{margin:"5px 0 0"}}>Upload the prepared official PDF for each person. Files are stored privately and become downloadable to that recipient when released. PDF only, maximum 15 MB.</p></div>
 <div style={{overflowX:"auto",marginTop:16}}><table className="table"><thead><tr><th>Recipient</th><th>Document</th><th>Status</th>{admin&&<th>Upload / actions</th>}</tr></thead><tbody>{rows.length?rows.map(row=><tr key={row.id}><td>{row.recipient_name||"Unassigned"}<div className="muted">{row.recipient_email||""}</div></td><td>{row.storage_path?<><FileText size={15} style={{verticalAlign:"middle",marginRight:5}}/>{row.original_filename||kind+" PDF"}<div className="muted">{row.file_size_bytes?Math.ceil(row.file_size_bytes/1024)+" KB":""}</div></>:"No PDF uploaded"}</td><td>{row.storage_path&&row.status==="released"?"Available to recipient":row.status||"Draft"}</td>{admin&&<td><div style={{display:"flex",gap:8,alignItems:"center",flexWrap:"wrap"}}><label className="secondary" style={{display:"inline-flex",gap:7,alignItems:"center",padding:"7px 10px",cursor:busy?"wait":"pointer",borderRadius:6}}><Upload size={15}/>{row.storage_path?"Replace PDF":"Upload PDF"}<input type="file" accept="application/pdf,.pdf" disabled={busy} onChange={e=>{const file=e.target.files?.[0];e.target.value="";if(file)upload(row,file)}} style={{display:"none"}}/></label>{row.storage_path&&<button className="secondary" disabled={busy} onClick={()=>remove(row)}><Trash2 size={14}/> Remove</button>}</div></td>}</tr>):<tr><td colSpan={admin?4:3} className="muted">{busy?"Loading tax documents…":"No recipients listed for this year and document type. "+(admin?"Use Add missing recipients to prepare the upload list.":"")}</td></tr>}</tbody></table></div>
 {admin&&<p className="muted" style={{marginTop:14}}><Lock size={14} style={{verticalAlign:"middle",marginRight:5}}/>Admin upload controls. Uploading a PDF releases it to the assigned account. Verify the recipient before uploading.</p>}
 </section></div>
}