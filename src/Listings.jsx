import {useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {Upload,RefreshCw,CheckCircle2,AlertCircle,FileText,Send,Save} from "lucide-react";

const blank={property_address:"",unit_number:"",city:"",province:"ON",postal_code:"",property_type:"RESIDENTIAL",listing_type:"SALE",asking_price:"",listing_start_date:"",listing_expiry_date:"",notes:""};
const defaults=[{code:"LISTING_AGREEMENT",label:"Listing Agreement",required:true},{code:"MLS_DATA",label:"MLS Data / Listing Information",required:true},{code:"PROPERTY_DETAILS",label:"Property Details / Feature Sheet",required:true},{code:"SELLER_DIRECTION",label:"Seller Direction / Authorization",required:true},{code:"ID_FINTRAC",label:"Identification / FINTRAC",required:true},{code:"OTHER",label:"Other Supporting Documents",required:false}];
const fieldStyle={width:"100%",boxSizing:"border-box",minHeight:36,padding:"7px 9px",border:"1px solid #d0d5dd",borderRadius:6};
const labelStyle={display:"grid",gap:4,fontSize:12,fontWeight:600};
const statusLabel=s=>({DRAFT:"Draft",SUBMITTED:"Awaiting review",NEEDS_CHANGES:"Changes requested",APPROVED:"Approved — awaiting MLS",PUBLISHED:"Published to MLS"}[s]||s||"—");
export default function Listings({user,agentId,adminMode=false}){
 const [rows,setRows]=useState([]),[docs,setDocs]=useState([]),[requirements,setRequirements]=useState(defaults),[companyId,setCompanyId]=useState(""),[selected,setSelected]=useState(null),[form,setForm]=useState({...blank}),[newListing,setNewListing]=useState(false),[uploadType,setUploadType]=useState(defaults[0].code),[fileBatch,setFileBatch]=useState([]),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[error,setError]=useState(""),[message,setMessage]=useState(""),[mlsNumber,setMlsNumber]=useState(""),[adminNotes,setAdminNotes]=useState("");
 const isAdmin=adminMode;
 const load=useCallback(async()=>{
  if(!supabase){setLoading(false);return}
  setLoading(true);setError("");
  const {data:company}=await supabase.from("dv_accounting_companies").select("id").limit(1).maybeSingle();
  if(company?.id)setCompanyId(company.id);
  const {data:req}=company?.id?await supabase.from("dv_accounting_settings").select("value").eq("company_id",company.id).eq("key","LISTING_DOCUMENT_REQUIREMENTS").maybeSingle():{data:null};
  const saved=req?.value;
  if(Array.isArray(saved)&&saved.length)setRequirements(saved.filter(x=>x&&x.code&&x.label).map(x=>({code:String(x.code),label:String(x.label),required:x.required!==false})));
  let q=supabase.from("dv_accounting_listing_submissions").select("*").order("created_at",{ascending:false});
  if(!isAdmin)q=q.eq("agent_id",agentId);
  const {data,error:e}=await q;
  if(e)setError("Could not load listing submissions: "+e.message);else setRows(data||[]);
  setLoading(false);
 },[isAdmin,agentId]);
 useEffect(()=>{load()},[load]);
 const loadDocs=useCallback(async(id)=>{if(!id){setDocs([]);return}const {data,error:e}=await supabase.from("dv_accounting_listing_documents").select("*").eq("listing_id",id).order("created_at");if(e)setError(e.message);else setDocs(data||[])},[]);
 function startNew(){setSelected(null);setForm({...blank});setDocs([]);setNewListing(true);setFileBatch([]);setMessage("");setError("");setMlsNumber("");setAdminNotes("")}
 async function openListing(row){setSelected(row);setForm({...blank,...row});setNewListing(false);setMlsNumber(row.mls_number||"");setAdminNotes(row.admin_notes||"");setMessage("");setError("");await loadDocs(row.id)}
 async function saveDraft(submit=false){
  if(!agentId&&!isAdmin){setError("Your login is not linked to an active agent profile.");return}
  if(!String(form.property_address||"").trim()||!String(form.city||"").trim()){setError("Property address and city are required.");return}
  if(submit&&!selected?.id){setError("Save the listing draft first, upload the paperwork, then submit it for review.");return}
  if(submit){const missing=requirements.filter(r=>r.required&&!docs.some(d=>d.document_type===r.code));if(missing.length){setError("Upload required listing documents before submitting: "+missing.map(x=>x.label).join(", "));return}}
  setBusy(true);setError("");setMessage("");
  const payload={property_address:String(form.property_address).trim(),unit_number:form.unit_number||"",city:String(form.city).trim(),province:form.province||"ON",postal_code:form.postal_code||"",property_type:form.property_type||"RESIDENTIAL",listing_type:form.listing_type||"SALE",asking_price:form.asking_price?Number(form.asking_price):null,listing_start_date:form.listing_start_date||null,listing_expiry_date:form.listing_expiry_date||null,notes:form.notes||"",status:submit?"SUBMITTED":(selected?.status==="NEEDS_CHANGES"?"NEEDS_CHANGES":"DRAFT"),updated_at:new Date().toISOString()};
  let result;
  if(selected?.id)result=await supabase.from("dv_accounting_listing_submissions").update(payload).eq("id",selected.id).select().single();
  else result=await supabase.from("dv_accounting_listing_submissions").insert([{...payload,agent_id:agentId,company_id:companyId,created_by:user?.id||null}]).select().single();
  if(result.error){setError("Could not save listing: "+result.error.message);setBusy(false);return}
  setSelected(result.data);setForm({...blank,...result.data});setNewListing(false);setMessage(submit?"Listing paperwork submitted for admin review.":"Listing draft saved. Upload the paperwork before submitting.");await load();await loadDocs(result.data.id);setBusy(false);
 }
 async function uploadFiles(){
  if(!selected?.id||!fileBatch.length){setError("Save the listing draft and select one or more files first.");return}
  setBusy(true);setError("");let count=0;
  for(const f of fileBatch){
   const safe=f.name.replace(/[^a-zA-Z0-9._-]/g,"_"),path="listings/"+selected.id+"/"+String(user.id)+"/"+Date.now()+"-"+count+"-"+safe;
   const {error:upError}=await supabase.storage.from("dv-trade-documents").upload(path,f,{upsert:false,contentType:f.type||"application/octet-stream"});
   if(upError){setError("Upload failed for "+f.name+": "+upError.message);break}
   const {data,error:e}=await supabase.from("dv_accounting_listing_documents").insert([{listing_id:selected.id,document_type:uploadType,document_name:f.name,storage_path:path,mime_type:f.type||null,file_size:f.size,uploaded_by:user.id}]).select().single();
   if(e){await supabase.storage.from("dv-trade-documents").remove([path]);setError("Could not register "+f.name+": "+e.message);break}
   count++;setDocs(old=>[...old,data]);
  }
  if(count===fileBatch.length){setFileBatch([]);setMessage(count+" listing document(s) uploaded.")}
  setBusy(false);await loadDocs(selected.id);
 }
 async function adminUpdate(status){
  if(!selected?.id)return;
  if(status==="APPROVED"){const missing=requirements.filter(r=>r.required&&!docs.some(d=>d.document_type===r.code));if(missing.length){setError("Cannot approve until required listing documents are uploaded: "+missing.map(x=>x.label).join(", "));return}}
  if(status==="PUBLISHED"&&!String(mlsNumber||"").trim()){setError("Enter the MLS number after the listing has been entered into REALM MLS.");return}
  if(status==="PUBLISHED"&&!selected?.status?.match(/APPROVED|PUBLISHED/)){setError("Approve the paperwork before marking the listing published.");return}
  setBusy(true);setError("");setMessage("");
  const {data,error:e}=await supabase.from("dv_accounting_listing_submissions").update({status,mls_number:status==="PUBLISHED"?mlsNumber.trim():(selected.mls_number||null),admin_notes:adminNotes,reviewed_by:user?.id||null,reviewed_at:new Date().toISOString(),published_at:status==="PUBLISHED"?new Date().toISOString():selected.published_at||null,updated_at:new Date().toISOString()}).eq("id",selected.id).select().single();
  if(e){setError("Could not update listing: "+e.message);setBusy(false);return}
  setSelected(data);setForm({...blank,...data});setMlsNumber(data.mls_number||"");setMessage(status==="NEEDS_CHANGES"?"Changes requested.":status==="APPROVED"?"Paperwork approved. Enter the listing in REALM MLS, then record its MLS number and mark it published.":"Listing marked as published with MLS number "+data.mls_number+".");
  await load();setBusy(false);
 }
 async function openDocument(d){const {data,error:e}=await supabase.storage.from("dv-trade-documents").createSignedUrl(d.storage_path,3600);if(e){setError(e.message);return}window.open(data.signedUrl,"_blank","noopener,noreferrer")}
 const canEdit=!isAdmin&&(!selected||["DRAFT","NEEDS_CHANGES"].includes(selected.status));
 const visibleRequirements=useMemo(()=>requirements,[requirements]);
 const inp=(key,caption,type="text",opts=null)=><label style={labelStyle}>{caption}{opts?<select disabled={!canEdit} style={fieldStyle} value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}>{opts.map(o=><option key={o[0]} value={o[0]}>{o[1]}</option>)}</select>:<input disabled={!canEdit} style={fieldStyle} type={type} value={form[key]??""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))} />}</label>;
 return <div style={{display:"grid",gap:14}}>
  <div className="pagehead"><div><h1>Listings</h1><p>Listing paperwork submission, compliance review, and REALM MLS tracking.</p></div>{!isAdmin&&<button className="primary" type="button" onClick={startNew}>+ New Listing</button>}</div>
  {error&&<div className="notice" role="alert"><AlertCircle size={16}/> {error}</div>}{message&&<div className="notice" role="status"><CheckCircle2 size={16}/> {message}</div>}
  <div style={{display:"grid",gridTemplateColumns:isAdmin?"minmax(260px,0.8fr) minmax(0,1.6fr)":"1fr",gap:12,alignItems:"start"}}>
   <section className="panel" style={{padding:12}}><div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{isAdmin?"Listing Review Queue":"My Listings"}</h2><button className="secondary" type="button" onClick={load}><RefreshCw size={14}/></button></div>
    {loading?<p className="muted">Loading…</p>:!rows.length?<p className="muted">No listing submissions yet.</p>:<div style={{display:"grid",gap:6}}>{rows.map(row=><button type="button" key={row.id} onClick={()=>openListing(row)} style={{textAlign:"left",padding:9,border:"1px solid "+(selected?.id===row.id?"#9e8556":"#e4e7ec"),borderRadius:7,background:selected?.id===row.id?"#f8f5ee":"white",cursor:"pointer"}}><b style={{fontSize:13}}>{row.property_address}{row.unit_number?" #"+row.unit_number:""}</b><div className="muted" style={{fontSize:11}}>{row.city}, {row.province} · {statusLabel(row.status)}</div>{row.mls_number&&<div style={{fontSize:11}}>MLS: {row.mls_number}</div>}{isAdmin&&<div className="muted" style={{fontSize:11}}>Agent ID: {row.agent_id}</div>}</button>)}</div>}
   </section>
   <section className="panel" style={{padding:12}}>
    {!selected&&!newListing?<div className="muted">{isAdmin?"Select a listing from the queue to review.":"Create a listing submission to begin."}</div>:<>
     <div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{selected?form.property_address||"Listing details":"New Listing Submission"}</h2>{selected&&<span className="pill">{statusLabel(selected.status)}</span>}</div>
     <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:9}}>
      {inp("property_address","Property address *")}{inp("unit_number","Unit #")}{inp("city","City *")}{inp("province","Province", "text", [["ON","Ontario"],["AB","Alberta"],["BC","British Columbia"],["QC","Quebec"],["Other","Other"]])}{inp("postal_code","Postal code")}{inp("property_type","Property type","text",[["RESIDENTIAL","Residential"],["CONDO","Condo"],["COMMERCIAL","Commercial"],["LAND","Land"],["OTHER","Other"]])}{inp("listing_type","Listing type","text",[["SALE","For Sale"],["LEASE","For Lease"]])}{inp("asking_price","Asking price","number")}{inp("listing_start_date","Listing start date","date")}{inp("listing_expiry_date","Listing expiry date","date")}
     </div>
     <label style={{...labelStyle,marginTop:9}}>Notes / special instructions<textarea disabled={!canEdit} rows={3} style={fieldStyle} value={form.notes||""} onChange={e=>setForm(v=>({...v,notes:e.target.value}))}/></label>
     {canEdit&&<div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}><button className="secondary" type="button" disabled={busy} onClick={()=>saveDraft(false)}><Save size={14}/> Save Draft</button>{selected&&<button className="primary" type="button" disabled={busy} onClick={()=>saveDraft(true)}><Send size={14}/> Submit for Review</button>}</div>}
     {selected&&<div style={{marginTop:12,borderTop:"1px solid #eaecf0",paddingTop:10}}><h3 style={{fontSize:14,margin:"0 0 8px"}}>Listing Paperwork</h3><div style={{display:"grid",gap:5}}>{visibleRequirements.map(r=>{const found=docs.filter(d=>d.document_type===r.code);return <div key={r.code} style={{display:"flex",gap:8,alignItems:"center",fontSize:12,padding:"5px 0",borderBottom:"1px solid #f2f4f7"}}><FileText size={14}/><span style={{flex:1}}>{r.label}{r.required?" *":""}</span><span className="muted">{found.length?"✓ "+found.length+" file(s)":"Not uploaded"}</span></div>})}</div>
      {canEdit&&<div style={{display:"grid",gridTemplateColumns:"minmax(150px,1fr) minmax(160px,1.4fr) auto",gap:7,alignItems:"end",marginTop:9}}><label style={labelStyle}>Document type<select style={fieldStyle} value={uploadType} onChange={e=>setUploadType(e.target.value)}>{requirements.map(r=><option key={r.code} value={r.code}>{r.label}</option>)}</select></label><label style={labelStyle}>Choose file(s)<input style={fieldStyle} type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" onChange={e=>setFileBatch(Array.from(e.target.files||[]))}/></label><button className="secondary" type="button" disabled={busy||!fileBatch.length} onClick={uploadFiles}><Upload size={14}/> Upload</button></div>}
      {docs.map(d=><div key={d.id} style={{display:"flex",alignItems:"center",gap:7,padding:"5px 0",fontSize:12}}><FileText size={14}/><span style={{flex:1}}>{d.document_name}<small className="muted" style={{display:"block"}}>{requirements.find(r=>r.code===d.document_type)?.label||d.document_type}</small></span><button type="button" className="textbutton" onClick={()=>openDocument(d)}>View</button></div>)}
     </div>}
     {isAdmin&&selected&&<div style={{marginTop:14,paddingTop:12,borderTop:"1px solid #eaecf0"}}><h3 style={{fontSize:14,margin:"0 0 8px"}}>Admin Review & MLS Publication</h3><label style={labelStyle}>Review notes<textarea rows={2} style={fieldStyle} value={adminNotes} onChange={e=>setAdminNotes(e.target.value)}/></label><label style={{...labelStyle,marginTop:8}}>MLS number (enter after uploading to REALM MLS)<input style={fieldStyle} value={mlsNumber} onChange={e=>setMlsNumber(e.target.value)} placeholder="Enter assigned MLS number"/></label><div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}><button className="secondary" type="button" disabled={busy} onClick={()=>adminUpdate("NEEDS_CHANGES")}>Request Changes</button><button className="primary" type="button" disabled={busy||selected.status==="PUBLISHED"} onClick={()=>adminUpdate("APPROVED")}><CheckCircle2 size={14}/> Approve Paperwork</button><button className="primary" type="button" disabled={busy||!mlsNumber.trim()||!["APPROVED","PUBLISHED"].includes(selected.status)} onClick={()=>adminUpdate("PUBLISHED")}>Mark Published</button></div><p className="muted" style={{fontSize:11}}>Approval does not publish to REALM automatically. Enter the listing in REALM MLS first, then record the MLS number and mark Published.</p></div>}
    </>}
   </section>
  </div>
 </div>
}
export function AgentListingsWorkspace({user,agentId,TradePortal}){
 const [mode,setMode]=useState("LISTINGS");
 return <div><div className="tx-tabs" style={{display:"flex",gap:6,padding:"8px 12px",flexWrap:"wrap"}}><button type="button" className={mode==="LISTINGS"?"active":""} onClick={()=>setMode("LISTINGS")}>Listings</button><button type="button" className={mode==="TRADES"?"active":""} onClick={()=>setMode("TRADES")}>Trade Submissions</button></div>{mode==="LISTINGS"?<Listings user={user} agentId={agentId}/>:<TradePortal user={user} agentId={agentId}/>}</div>
}
