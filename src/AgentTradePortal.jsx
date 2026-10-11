import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Clock3, FileText, Plus, RefreshCw, Send, Upload, XCircle, ExternalLink } from "lucide-react";
import { supabase } from "./lib/supabase";

const blank = {
  transaction_number:"", transaction_type:"BUY_SELL", side:"SELLER", property_address:"",
  street_number:"", street_name:"", unit_number:"", city:"", province:"ON", postal_code:"",
  mls_number:"", transaction_date:new Date().toISOString().slice(0,10), offer_date:"",
  firm_date:"", close_date:"", sale_price:"", gross_commission:"", client_name:"",
  buyer_name:"", buyer_email:"", buyer_phone:"", buyer_company:"",
  seller_name:"", seller_email:"", seller_phone:"", seller_company:"", notes:""
};
const labelStatus = s => ({DRAFT:"Draft",SUBMITTED:"Awaiting review",NEEDS_CHANGES:"Changes requested",APPROVED:"Approved / transferred"}[s]||s||"Draft");
const money = v => new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(v||0));
const displayDate = v => v ? new Date(v+"T12:00:00").toLocaleDateString("en-CA") : "—";
const inputFields = [
  ["transaction_number","Agent reference / trade number"],["transaction_type","Transaction type"],["side","Representation side"],
  ["property_address","Full property address"],["street_number","Street number"],["street_name","Street name"],["unit_number","Unit"],["city","City"],["province","Province"],["postal_code","Postal code"],["mls_number","MLS number"],["transaction_date","Trade / entry date"],["offer_date","Offer date"],["firm_date","Firm date"],["close_date","Closing date"],["sale_price","Sale / lease price"],["gross_commission","Expected gross commission"],["client_name","Client / party summary"],
  ["buyer_name","Buyer name"],["buyer_email","Buyer email"],["buyer_phone","Buyer phone"],["buyer_company","Buyer company"],
  ["seller_name","Seller name"],["seller_email","Seller email"],["seller_phone","Seller phone"],["seller_company","Seller company"],["notes","Notes for Trade Admin"]
];
function Field({label,children}) { return <label className="agent-trade-field"><span>{label}</span>{children}</label> }
function statusPill(status){return <span className="pill" style={{background:status==="APPROVED"?"#e8f7ee":status==="SUBMITTED"?"#fff3d9":status==="NEEDS_CHANGES"?"#fff0f0":"#edf1f7",color:status==="APPROVED"?"#167344":status==="SUBMITTED"?"#875600":status==="NEEDS_CHANGES"?"#b42318":"#344054"}}>{labelStatus(status)}</span>}

export default function AgentTradePortal({user,agentId,adminMode=false}) {
 const [submissions,setSubmissions]=useState([]),[docs,setDocs]=useState([]),[agents,setAgents]=useState([]);
 const [selected,setSelected]=useState(null),[form,setForm]=useState({...blank}),[file,setFile]=useState(null),[docType,setDocType]=useState("APS");
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[message,setMessage]=useState(""),[reviewNotes,setReviewNotes]=useState("");
 const [previewUrl,setPreviewUrl]=useState(""),[previewDoc,setPreviewDoc]=useState(null);
 const [filter,setFilter]=useState("SUBMITTED");

 const load = useCallback(async()=>{
   if(!supabase)return;
   setError("");
   const query=supabase.from("dv_accounting_agent_trade_submissions").select("*").order("created_at",{ascending:false});
   const {data,error:e}=adminMode?await query:await query.eq("agent_id",agentId);
   if(e){setError(e.message);return}
   setSubmissions(data||[]);
   if(adminMode){
     const ids=[...new Set((data||[]).map(x=>x.agent_id))];
     if(ids.length){const a=await supabase.from("dv_accounting_agents").select("id,agent_number,first_name,last_name,email").in("id",ids);setAgents(a.data||[])}
   }
 },[adminMode,agentId]);

 const loadDocs=useCallback(async(id)=>{
   if(!id||!supabase){setDocs([]);return}
   const {data,error:e}=await supabase.from("dv_accounting_agent_trade_documents").select("*").eq("submission_id",id).order("created_at");
   if(e){setError(e.message);setDocs([])}else setDocs(data||[]);
 },[]);

 useEffect(()=>{load()},[load]);
 useEffect(()=>{const timer=setInterval(load,45000);return()=>clearInterval(timer)},[load]);
 useEffect(()=>{if(!adminMode||!supabase)return;const channel=supabase.channel("dv-agent-trade-submission-alerts").on("postgres_changes",{event:"INSERT",schema:"public",table:"dv_accounting_agent_trade_submissions"},payload=>{if(payload.new?.status==="SUBMITTED"){setMessage("New agent trade submission received. Please review the queue.");load();if(typeof window!=="undefined"&&"Notification" in window&&Notification.permission==="granted")new Notification("Dream Valley — Trade submitted",{body:"An agent submitted a trade for approval."})}}).subscribe();return()=>{supabase.removeChannel(channel)}},[adminMode,load]);
 useEffect(()=>{if(selected?.id)loadDocs(selected.id);else setDocs([])},[selected?.id,loadDocs]);

 function startNew(){setSelected(null);setForm({...blank});setMessage("");setError("");}
 function editSubmission(s){setSelected(s);setForm({...blank,...(s.payload||{})});setMessage("");setError("");setReviewNotes(s.review_notes||"");}
 async function saveDraft({submit=false}={}){
   if(!supabase||!agentId){setError("Your login is not linked to an active Dream Valley agent record. Ask the administrator to make sure your login email matches your agent profile email.");return}
   if(submit&&(!selected?.id||docs.length===0)){setError("Save the draft and upload at least one supporting document before submitting for review.");return}
   if(!form.property_address.trim()||!form.close_date||!form.transaction_type){setError("Please enter the property address, transaction type and closing date.");return}
   setBusy(true);setError("");setMessage("");
   const payload={...form, sale_price:form.sale_price===""?null:Number(form.sale_price),gross_commission:form.gross_commission===""?null:Number(form.gross_commission)};
   let row=selected;
   if(row?.id){
     const {data,error:e}=await supabase.from("dv_accounting_agent_trade_submissions").update({payload,status:submit?"SUBMITTED":row.status==="NEEDS_CHANGES"?"NEEDS_CHANGES":row.status,submitted_at:submit?new Date().toISOString():row.submitted_at,updated_at:new Date().toISOString()}).eq("id",row.id).select().single();
     if(e){setError(e.message);setBusy(false);return}row=data;
   }else{
     const {data,error:e}=await supabase.from("dv_accounting_agent_trade_submissions").insert([{agent_id:agentId,submitted_by:user.id,payload,status:submit?"SUBMITTED":"DRAFT",submitted_at:submit?new Date().toISOString():null}]).select().single();
     if(e){setError(e.message);setBusy(false);return}row=data;
   }
   setSelected(row);setSubmissions(old=>[row,...old.filter(x=>x.id!==row.id)]);
   setMessage(submit?"Trade submitted to the Trade Admin Manager for review.":"Draft saved.");
   setBusy(false);await loadDocs(row.id);await load();
 }
 async function uploadFile(){
   if(!file||!selected?.id||!supabase)return;
   setBusy(true);setError("");const safe=file.name.replace(/[^a-zA-Z0-9._-]/g,"_");
   const path=`${user.id}/${selected.id}/${Date.now()}-${safe}`;
   const {error:upError}=await supabase.storage.from("dv-trade-documents").upload(path,file,{upsert:false,contentType:file.type||"application/octet-stream"});
   if(upError){setError(upError.message);setBusy(false);return}
   const {data,error:e}=await supabase.from("dv_accounting_agent_trade_documents").insert([{submission_id:selected.id,document_type:docType,document_name:file.name,storage_path:path,mime_type:file.type||null,file_size:file.size,uploaded_by:user.id}]).select().single();
   if(e){await supabase.storage.from("dv-trade-documents").remove([path]);setError(e.message);setBusy(false);return}
   setDocs(old=>[...old,data]);setFile(null);setMessage("Document uploaded.");setBusy(false);
 }
 async function openDoc(doc){
   const {data,error:e}=await supabase.storage.from("dv-trade-documents").createSignedUrl(doc.storage_path,3600);
   if(e){setError(e.message);return}setPreviewDoc(doc);setPreviewUrl(data.signedUrl);
 }
 async function setDocMatch(doc,match_status){
   const {data,error:e}=await supabase.from("dv_accounting_agent_trade_documents").update({match_status}).eq("id",doc.id).select().single();
   if(e){setError(e.message);return}setDocs(old=>old.map(d=>d.id===doc.id?data:d));
 }
 async function review(status){
   if(!selected?.id)return;
   if(status==="APPROVED"&&(!docs.length||docs.some(d=>!["MATCH","NOT_APPLICABLE"].includes(d.match_status)))){setError("Before approval, upload at least one document and mark each document as Match or Not applicable after checking it against the entered trade details.");return}
   if(status==="NEEDS_CHANGES"&&!reviewNotes.trim()){setError("Please tell the agent what needs to be corrected.");return}
   setBusy(true);setError("");
   if(status==="APPROVED"){
     const {data,error:e}=await supabase.rpc("dv_accounting_approve_agent_trade_submission",{p_submission_id:selected.id});
     if(e){setError(e.message);setBusy(false);return}
     setMessage("Approved. A draft transaction has been created for the billing and payout workflow.");
   }else{
     const {error:e}=await supabase.rpc("dv_accounting_review_agent_trade_submission",{p_submission_id:selected.id,p_status:status,p_notes:reviewNotes});
     if(e){setError(e.message);setBusy(false);return}
     setMessage("Review decision saved and the agent can see your notes.");
   }
   setBusy(false);setSelected(null);await load();
 }
 const filtered=useMemo(()=>adminMode?submissions.filter(s=>filter==="ALL"||s.status===filter):submissions,[adminMode,filter,submissions]);
 const currentAgent=selected?agents.find(a=>a.id===selected.agent_id):null;
 const tradeSummary=selected?.payload||form;
 const mismatchCount=docs.filter(d=>d.match_status==="MISMATCH").length;

 return <div className="agent-trade-portal">
   <style>{`
   .agent-trade-portal{display:grid;gap:18px}.agent-trade-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.agent-trade-field{display:flex;flex-direction:column;gap:6px;font-size:13px;font-weight:650;color:#344054}.agent-trade-field input,.agent-trade-field select,.agent-trade-field textarea{width:100%;box-sizing:border-box;border:1px solid #d0d5dd;border-radius:8px;padding:10px;background:#fff;color:#101828;font:inherit;font-weight:400}.agent-trade-field textarea{min-height:76px}.agent-trade-wide{grid-column:1/-1}.agent-trade-layout{display:grid;grid-template-columns:minmax(280px,.85fr) minmax(0,1.6fr);gap:18px;align-items:start}.agent-trade-list{display:grid;gap:8px}.agent-trade-item{border:1px solid #e4e7ec;background:#fff;border-radius:10px;padding:12px;text-align:left;cursor:pointer;color:#101828}.agent-trade-item.selected{border-color:#9e8556;box-shadow:0 0 0 2px #9e855622}.agent-trade-item strong{display:block;margin-bottom:4px}.agent-trade-muted{color:#667085;font-size:12px}.agent-trade-doc{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:center;border:1px solid #eaecf0;border-radius:9px;padding:10px;margin-top:8px}.agent-trade-doc-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}.agent-trade-buttons{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}.agent-trade-alert{padding:11px 13px;border-radius:9px;background:#fff7e6;color:#875600;font-size:13px}.agent-trade-error{padding:11px 13px;border-radius:9px;background:#fff0f0;color:#b42318;font-size:13px}.agent-trade-success{padding:11px 13px;border-radius:9px;background:#e8f7ee;color:#167344;font-size:13px}.agent-trade-checks{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin:12px 0}.agent-trade-check{padding:10px;border:1px solid #eaecf0;border-radius:8px;font-size:13px}.agent-trade-check b{display:block;margin-bottom:4px}.agent-trade-compare{display:grid;grid-template-columns:1fr 1fr;gap:12px}.agent-trade-compare>div{border:1px solid #eaecf0;border-radius:9px;padding:12px}.agent-trade-preview{position:fixed;inset:4vh 4vw;z-index:2000;background:white;border-radius:12px;box-shadow:0 12px 50px #0004;display:flex;flex-direction:column;padding:14px}.agent-trade-preview iframe{flex:1;border:0;min-height:0}.agent-trade-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}.agent-trade-head h1{margin:0 0 5px}.agent-trade-count{display:inline-flex;align-items:center;justify-content:center;min-width:24px;height:24px;border-radius:20px;background:#9e8556;color:white;font-weight:700;font-size:12px;padding:0 6px}@media(max-width:900px){.agent-trade-layout{grid-template-columns:1fr}.agent-trade-grid,.agent-trade-checks,.agent-trade-compare{grid-template-columns:1fr}.agent-trade-head{flex-direction:column}.agent-trade-doc{grid-template-columns:1fr}.agent-trade-doc-actions{justify-content:flex-start}}
   `}</style>
   <div className="agent-trade-head"><div><h1>{adminMode?"Trade Admin Review":"My Trade Submissions"}</h1><p className="muted">{adminMode?"Review agent-entered information and uploaded documents before creating a billing and payout transaction.":"Create a trade, upload the supporting documents and submit everything for Trade Admin approval."}</p></div><div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button className="secondary" onClick={load}><RefreshCw size={16}/> Refresh</button>{!adminMode&&<button className="primary" onClick={startNew}><Plus size={16}/> New Trade</button>}</div></div>
   {error&&<div className="agent-trade-error"><AlertCircle size={16} style={{verticalAlign:"middle",marginRight:6}}/>{error}</div>}
   {message&&<div className="agent-trade-success"><CheckCircle2 size={16} style={{verticalAlign:"middle",marginRight:6}}/>{message}</div>}
   {adminMode&&<section className="panel"><div style={{display:"flex",gap:8,flexWrap:"wrap",alignItems:"center"}}><strong>Review queue</strong><span className="agent-trade-count">{submissions.filter(s=>s.status==="SUBMITTED").length}</span><span className="agent-trade-muted">awaiting review</span><div style={{marginLeft:"auto"}}><select value={filter} onChange={e=>setFilter(e.target.value)}><option value="SUBMITTED">Awaiting review</option><option value="NEEDS_CHANGES">Changes requested</option><option value="APPROVED">Approved</option><option value="ALL">All submissions</option></select></div></div></section>}
   <div className="agent-trade-layout">
     <section className="panel"><div className="paneltitle"><h2>{adminMode?"Submissions":"My submissions"}</h2></div><div className="agent-trade-list">{filtered.map(s=>{const a=agents.find(x=>x.id===s.agent_id);return <button key={s.id} className={"agent-trade-item "+(selected?.id===s.id?"selected":"")} onClick={()=>editSubmission(s)}><strong>{s.payload?.property_address||"Trade draft"}</strong><div className="agent-trade-muted">{adminMode?[a?.agent_number,[a?.first_name,a?.last_name].filter(Boolean).join(" ")].filter(Boolean).join(" · "):"Submitted "+displayDate(s.submitted_at||s.created_at)}</div><div style={{display:"flex",gap:8,alignItems:"center",marginTop:8,flexWrap:"wrap"}}>{statusPill(s.status)}<span className="agent-trade-muted">{s.payload?.close_date?("Closing "+displayDate(s.payload.close_date)):"No closing date"}</span></div></button>})}{!filtered.length&&<div className="empty small"><FileText/><h3>No submissions</h3><p>{adminMode?"No trades match this queue filter.":"Start a new trade to send it for review."}</p></div>}</div></section>
     <section className="panel">
       <div className="paneltitle"><div><h2>{adminMode?(selected?"Review Trade":"Select a submission"):(selected?"Trade Details":"Create a Trade")}</h2><p className="agent-trade-muted">{selected?"Last updated "+displayDate(selected.updated_at?.slice(0,10)||selected.created_at?.slice(0,10)):"Save a draft before uploading documents."}</p></div>{selected&&statusPill(selected.status)}</div>
       {!selected&&adminMode?<div className="empty"><ClipboardPlaceholder/><h3>Select a trade</h3><p>Choose a submission from the queue to compare details and documents.</p></div>:!adminMode&&(!selected||["DRAFT","NEEDS_CHANGES"].includes(selected.status))?<form onSubmit={e=>{e.preventDefault();saveDraft()}}>
         <div className="agent-trade-grid">{inputFields.map(([key,label])=><Field key={key} label={label}>
           {key==="transaction_type"?<select value={form[key]||"BUY_SELL"} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}><option value="BUY_SELL">Buy / Sell</option><option value="LEASE">Lease</option></select>
           :key==="side"?<select value={form[key]||"SELLER"} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}><option value="SELLER">Listing / Seller side</option><option value="BUYER">Buyer side</option><option value="LANDLORD">Landlord side</option><option value="TENANT">Tenant side</option></select>
           :["transaction_date","offer_date","firm_date","close_date"].includes(key)?<input type="date" value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>
           :["sale_price","gross_commission"].includes(key)?<input type="number" min="0" step=".01" value={form[key]??""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>
           :key==="notes"?<textarea value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>
           :<input value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>}
         </Field>)}</div>
         {selected?.status==="NEEDS_CHANGES"&&selected.review_notes&&<div className="agent-trade-alert" style={{marginTop:12}}><strong>Trade Admin notes:</strong> {selected.review_notes}</div>}
         <div className="agent-trade-buttons"><button className="secondary" type="submit" disabled={busy}>{busy?"Saving…":"Save Draft"}</button><button className="primary" type="button" disabled={busy||!selected?.id} onClick={()=>saveDraft({submit:true})}><Send size={16}/> {busy?"Submitting…":"Submit for Review"}</button></div>
       </form>:selected?<div>
         <div className="agent-trade-checks">{[["Property",tradeSummary.property_address],["Transaction",tradeSummary.transaction_type],["Side",tradeSummary.side],["Sale / lease price",tradeSummary.sale_price?money(tradeSummary.sale_price):"Not entered"],["Gross commission",tradeSummary.gross_commission?money(tradeSummary.gross_commission):"Not entered"],["Closing date",displayDate(tradeSummary.close_date)],["Buyer",tradeSummary.buyer_name],["Seller",tradeSummary.seller_name],["MLS number",tradeSummary.mls_number],["Agent notes",tradeSummary.notes]].map(([k,v])=><div className="agent-trade-check" key={k}><b>{k}</b>{v||"—"}</div>)}</div>
         <h3 style={{marginTop:20}}>Supporting documents & information match</h3>
         <p className="agent-trade-muted">Compare each uploaded document with the entered trade details. Mark Match only after verifying the document itself. The system does not claim OCR verification of scanned images.</p>
         {!docs.length&&<div className="agent-trade-alert">No supporting documents have been uploaded.</div>}
         {docs.map(d=><div className="agent-trade-doc" key={d.id}><div><strong>{d.document_name}</strong><div className="agent-trade-muted">{d.document_type} · {Math.max(1,Math.round((d.file_size||0)/1024))} KB · <span className="pill" style={{background:d.match_status==="MATCH"?"#e8f7ee":d.match_status==="MISMATCH"?"#fff0f0":"#edf1f7",color:d.match_status==="MATCH"?"#167344":d.match_status==="MISMATCH"?"#b42318":"#344054"}}>{d.match_status==="PENDING"?"Not reviewed":d.match_status==="MATCH"?"Match":d.match_status==="MISMATCH"?"Mismatch":"Not applicable"}</span></div>{d.match_notes&&<div className="agent-trade-muted">{d.match_notes}</div>}</div><div className="agent-trade-doc-actions"><button className="secondary" type="button" onClick={()=>openDoc(d)}><ExternalLink size={14}/> View</button>{adminMode&&selected.status==="SUBMITTED"&&<><button className="secondary" type="button" onClick={()=>setDocMatch(d,"MATCH")}><CheckCircle2 size={14}/> Match</button><button className="secondary" type="button" onClick={()=>setDocMatch(d,"MISMATCH")}><XCircle size={14}/> Mismatch</button><button className="textbutton" type="button" onClick={()=>setDocMatch(d,"NOT_APPLICABLE")}>N/A</button></>}</div></div>)}
         {!adminMode&&["DRAFT","NEEDS_CHANGES"].includes(selected.status)&&<div style={{marginTop:16,padding:12,border:"1px dashed #d0d5dd",borderRadius:9}}><div className="agent-trade-grid"><Field label="Document type"><select value={docType} onChange={e=>setDocType(e.target.value)}><option value="APS">Agreement of Purchase and Sale / Lease</option><option value="MLS">MLS / Listing sheet</option><option value="COMMISSION">Commission confirmation</option><option value="ID">Other required compliance document</option><option value="OTHER">Other supporting document</option></select></Field><Field label="Select file"><input type="file" accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" onChange={e=>setFile(e.target.files?.[0]||null)}/></Field></div><button className="secondary" style={{marginTop:10}} type="button" disabled={!file||busy} onClick={uploadFile}><Upload size={16}/> Upload Document</button><div className="agent-trade-muted" style={{marginTop:6}}>PDF, JPG, PNG, TIFF or Word; maximum 25 MB per file.</div></div>}
         {adminMode&&selected.status==="SUBMITTED"&&<div style={{marginTop:18}}><Field label="Review notes (required when requesting changes)"><textarea value={reviewNotes} onChange={e=>setReviewNotes(e.target.value)} placeholder="List any missing document or mismatch to correct."/></Field><div className="agent-trade-buttons"><button className="secondary" disabled={busy} onClick={()=>review("NEEDS_CHANGES")}>Request Changes</button><button className="primary" disabled={busy||!docs.length||docs.some(d=>!["MATCH","NOT_APPLICABLE"].includes(d.match_status))||mismatchCount>0} onClick={()=>review("APPROVED")}><CheckCircle2 size={16}/> Approve & Create Transaction</button></div><p className="agent-trade-muted">Approval creates a DRAFT transaction linked to this agent so accounting can complete billing, commission calculations and payout workflow.</p></div>}
         {selected.status==="APPROVED"&&<div className="agent-trade-success" style={{marginTop:14}}>This trade was approved and transferred to the Transactions workflow. Transaction ID: {selected.transaction_id||"—"}</div>}
       </div>:null}
     </section>
   </div>
   {previewUrl&&<div className="agent-trade-preview"><div style={{display:"flex",alignItems:"center",gap:12,marginBottom:12}}><strong>{previewDoc?.document_name}</strong><button className="secondary" style={{marginLeft:"auto"}} onClick={()=>{setPreviewUrl("");setPreviewDoc(null)}}><X size={16}/> Close preview</button></div><iframe title="Trade document preview" src={previewUrl}/></div>}
 </div>
}
function ClipboardPlaceholder(){return <AlertCircle size={26}/>}
