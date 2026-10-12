import {useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import AgentSearchSelect from "./AgentSearchSelect";
import {Upload,RefreshCw,CheckCircle2,AlertCircle,FileText,Send,Save} from "lucide-react";
import { PDFDocument } from "pdf-lib";
import * as pdfjsLib from "pdfjs-dist/legacy/build/pdf.mjs";
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";
pdfjsLib.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

const blank={property_address:"",unit_number:"",city:"",province:"ON",postal_code:"",property_type:"RESIDENTIAL",listing_type:"SALE",asking_price:"",listing_start_date:"",listing_expiry_date:"",notes:""};
const defaults=[{code:"LISTING_AGREEMENT",label:"Listing Agreement",required:true},{code:"MLS_DATA",label:"MLS Data / Listing Information",required:true},{code:"PROPERTY_DETAILS",label:"Property Details / Feature Sheet",required:true},{code:"SELLER_DIRECTION",label:"Seller Direction / Authorization",required:true},{code:"ID_FINTRAC",label:"Identification / FINTRAC",required:true},{code:"OTHER",label:"Other Supporting Documents",required:false}];
const fieldStyle={width:"100%",boxSizing:"border-box",minHeight:36,padding:"7px 9px",border:"1px solid #d0d5dd",borderRadius:6};
const labelStyle={display:"grid",gap:4,fontSize:12,fontWeight:600};
const statusLabel=s=>({DRAFT:"Draft",SUBMITTED:"Awaiting review",NEEDS_CHANGES:"Changes requested",APPROVED:"Approved — awaiting MLS",PUBLISHED:"Published to MLS"}[s]||s||"—");
export default function Listings({user,agentId,adminMode=false}){
 const [rows,setRows]=useState([]),[docs,setDocs]=useState([]),[requirements,setRequirements]=useState(defaults),[companyId,setCompanyId]=useState(""),[agents,setAgents]=useState([]),[assignedAgentId,setAssignedAgentId]=useState(""),[additionalAgentIds,setAdditionalAgentIds]=useState([]),[additionalAgentSearch,setAdditionalAgentSearch]=useState(""),[selected,setSelected]=useState(null),[form,setForm]=useState({...blank}),[newListing,setNewListing]=useState(false),[uploadType,setUploadType]=useState(defaults[0].code),[fileBatch,setFileBatch]=useState([]),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[error,setError]=useState(""),[message,setMessage]=useState(""),[mlsNumber,setMlsNumber]=useState(""),[adminNotes,setAdminNotes]=useState(""),[autoSplit,setAutoSplit]=useState(false),[splitPreview,setSplitPreview]=useState(null),[splitting,setSplitting]=useState(false);
 const isAdmin=adminMode;
 const load=useCallback(async()=>{
  if(!supabase){setLoading(false);return}
  setLoading(true);setError("");
  const {data:company}=await supabase.from("dv_accounting_companies").select("id").limit(1).maybeSingle();
  if(company?.id)setCompanyId(company.id);
  const {data:agentRows,error:agentError}=await supabase.from("dv_accounting_agents").select("*");if(agentError)setError("Could not load agents: "+agentError.message);else setAgents((agentRows||[]).filter(a=>a.active!==false).sort((a,b)=>String(a.last_name||"").localeCompare(String(b.last_name||""))));
  if(company?.id){
   const {data:settings}=await supabase.from("dv_accounting_settings").select("key,value").eq("company_id",company.id).in("key",["TRADE_DOCUMENT_TYPES","TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE","LISTING_DOCUMENT_REQUIREMENTS"]);
   const map=Object.fromEntries((settings||[]).map(x=>[x.key,x.value]));
   const master=Array.isArray(map.TRADE_DOCUMENT_TYPES)?map.TRADE_DOCUMENT_TYPES.filter(x=>Array.isArray(x)&&x.length>=2).map(([code,label])=>({code:String(code),label:String(label)})):[];
   const listingRules=map.TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE?.LISTING;
   const legacy=Array.isArray(map.LISTING_DOCUMENT_REQUIREMENTS)?map.LISTING_DOCUMENT_REQUIREMENTS:[];
   const types=Array.isArray(listingRules?.types)?listingRules.types:[];
   const required=Array.isArray(listingRules?.required)?listingRules.required:types;
   const configured=types.map(code=>master.find(x=>x.code===String(code))||legacy.find(x=>String(x.code)===String(code))||{code:String(code),label:String(code)}).filter(x=>x.code);
   if(configured.length)setRequirements(configured.map(x=>({...x,required:required.includes(x.code)})));
   else if(legacy.length)setRequirements(legacy.filter(x=>x&&x.code&&x.label).map(x=>({code:String(x.code),label:String(x.label),required:x.required!==false})));
  }
  let q=supabase.from("dv_accounting_listing_submissions").select("*").order("created_at",{ascending:false});
  if(!isAdmin)q=q.eq("agent_id",agentId);
  const {data,error:e}=await q;
  if(e)setError("Could not load listing submissions: "+e.message);else setRows(data||[]);
  setLoading(false);
 },[isAdmin,agentId]);
 useEffect(()=>{load()},[load]);
 const loadDocs=useCallback(async(id)=>{if(!id){setDocs([]);return}const {data,error:e}=await supabase.from("dv_accounting_listing_documents").select("*").eq("listing_id",id).order("created_at");if(e)setError(e.message);else setDocs(data||[])},[]);
 function startNew(){setSelected(null);setForm({...blank});setDocs([]);setNewListing(true);setFileBatch([]);setAssignedAgentId("");setAdditionalAgentIds([]);setAdditionalAgentSearch("");setMessage("");setError("");setMlsNumber("");setAdminNotes("")}
 async function openListing(row){setSelected(row);setForm({...blank,...row});setAssignedAgentId(row.agent_id||"");setAdditionalAgentIds(Array.isArray(row.additional_agent_ids)?row.additional_agent_ids.filter(id=>id!==row.agent_id):[]);setNewListing(false);setMlsNumber(row.mls_number||"");setAdminNotes(row.admin_notes||"");setMessage("");setError("");await loadDocs(row.id)}
 async function saveDraft(submit=false){
  const targetAgentId=isAdmin?(assignedAgentId||selected?.agent_id):agentId;if(!targetAgentId){setError(isAdmin?"Select the agent this listing belongs to.":"Your login is not linked to an active agent profile.");return}
  if(!String(form.property_address||"").trim()||!String(form.city||"").trim()){setError("Property address and city are required.");return}
  if(submit&&!selected?.id){setError("Save the listing draft first, upload the paperwork, then submit it for review.");return}
  if(submit){const missing=requirements.filter(r=>r.required&&!docs.some(d=>d.document_type===r.code));if(missing.length){setError("Upload required listing documents before submitting: "+missing.map(x=>x.label).join(", "));return}}
  setBusy(true);setError("");setMessage("");
  const payload={property_address:String(form.property_address).trim(),additional_agent_ids:isAdmin?[...new Set([targetAgentId,...additionalAgentIds].filter(Boolean))]:[...new Set([agentId,...additionalAgentIds].filter(Boolean))],unit_number:form.unit_number||"",city:String(form.city).trim(),province:form.province||"ON",postal_code:form.postal_code||"",property_type:form.property_type||"RESIDENTIAL",listing_type:form.listing_type||"SALE",asking_price:form.asking_price?Number(form.asking_price):null,listing_start_date:form.listing_start_date||null,listing_expiry_date:form.listing_expiry_date||null,notes:form.notes||"",status:submit?"SUBMITTED":(selected?.status==="NEEDS_CHANGES"?"NEEDS_CHANGES":"DRAFT"),updated_at:new Date().toISOString()};
  let result;
  if(selected?.id)result=await supabase.from("dv_accounting_listing_submissions").update({...payload,...(isAdmin?{agent_id:targetAgentId}:{})}).eq("id",selected.id).select().single();
  else result=await supabase.from("dv_accounting_listing_submissions").insert([{...payload,agent_id:targetAgentId,company_id:companyId,created_by:user?.id||null}]).select().single();
  if(result.error){setError("Could not save listing: "+result.error.message);setBusy(false);return}
  setSelected(result.data);setAssignedAgentId(result.data.agent_id||targetAgentId);setAdditionalAgentIds(Array.isArray(result.data.additional_agent_ids)?result.data.additional_agent_ids.filter(id=>id!==result.data.agent_id):[]);setForm({...blank,...result.data});setNewListing(false);setMessage(submit?"Listing paperwork submitted for admin review.":"Listing draft saved. Upload the paperwork before submitting.");await load();await loadDocs(result.data.id);setBusy(false);
 }
 async function prepareSplitPreview(){
  if(!fileBatch.length){setError("Choose one or more files first.");return}
  const pdfs=fileBatch.filter(f=>f.type==="application/pdf"||/\.pdf$/i.test(f.name));
  if(!pdfs.length){setError("Auto-splitting works with PDF files. Turn it off to upload other file types normally.");return}
  setSplitting(true);setError("");setSplitPreview(null);
  try{
   const prepared=[];
   for(const file of fileBatch){
    if(!(file.type==="application/pdf"||/\.pdf$/i.test(file.name))){prepared.push({file,document_type:uploadType,document_name:file.name,pages:"Original file",needsReview:false});continue}
    const bytes=await file.arrayBuffer();
    const pdf=await pdfjsLib.getDocument({data:bytes.slice(0)}).promise;
    const pageTypes=[];
    for(let pageNo=1;pageNo<=pdf.numPages;pageNo++){
     const page=await pdf.getPage(pageNo);const content=await page.getTextContent();
     const text=content.items.map(item=>item.str||"").join(" ").toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
     let best={code:uploadType,score:0};
     for(const req of requirements){
      const label=String(req.label||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
      const code=String(req.code||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
      let score=0;
      if(label&&text.includes(label))score+=10;
      if(code&&text.includes(code))score+=8;
      const tokens=[...new Set((label+" "+code).split(/\s+/).filter(w=>w.length>3&&!["document","listing","other","supporting","information"].includes(w)))];
      for(const token of tokens)if(text.includes(token))score+=1;
      if(score>best.score)best={code:req.code,score};
     }
     pageTypes.push({pageNo,code:best.code,score:best.score});
    }
    const groups=[];
    for(const item of pageTypes){
     const last=groups[groups.length-1];
     if(last&&last.code===item.code){last.pages.push(item.pageNo);last.lowConfidence=last.lowConfidence||item.score<2}
     else groups.push({code:item.code,pages:[item.pageNo],lowConfidence:item.score<2});
    }
    for(let i=0;i<groups.length;i++){
     const group=groups[i];const output=await PDFDocument.create();const loaded=await PDFDocument.load(bytes);
     const copied=await output.copyPages(loaded,group.pages.map(p=>p-1));copied.forEach(p=>output.addPage(p));
     const blob=new Blob([await output.save()],{type:"application/pdf"});
     const base=file.name.replace(/\.pdf$/i,"");
     const label=requirements.find(r=>r.code===group.code)?.label||group.code;
     prepared.push({file:new File([blob],base+" - "+label+" - pages "+group.pages.join(",")+".pdf",{type:"application/pdf"}),document_type:group.code,document_name:base+" - "+label+".pdf",pages:group.pages.join(", "),needsReview:group.lowConfidence});
    }
   }
   setSplitPreview(prepared);
   setMessage("Review the split PDF files and document types before uploading. Pages with uncertain classifications are flagged for review.");
  }catch(e){setError("Could not split this PDF: "+(e?.message||String(e)));}
  finally{setSplitting(false)}
 }
 async function uploadFiles(){
  if(!selected?.id||(!fileBatch.length&&!splitPreview?.length)){setError("Save the listing draft and select one or more files first.");return}if(!user?.id){setError("Your login session is missing. Sign in again before uploading files.");return}
  if(autoSplit&&!splitPreview&&fileBatch.some(f=>f.type==="application/pdf"||/\.pdf$/i.test(f.name))){await prepareSplitPreview();return}
  setBusy(true);setError("");let count=0;
  const uploadQueue=splitPreview||fileBatch.map(file=>({file,document_type:uploadType,document_name:file.name}));
  for(const item of uploadQueue){
   const f=item.file;
   const documentType=item.document_type||uploadType;
   const documentName=item.document_name||f.name;
   const safe=f.name.replace(/[^a-zA-Z0-9._-]/g,"_"),path="listings/"+selected.id+"/"+String(user.id)+"/"+Date.now()+"-"+count+"-"+safe;
   const {error:upError}=await supabase.storage.from("dv-trade-documents").upload(path,f,{upsert:false,contentType:f.type||"application/octet-stream"});
   if(upError){setError("Upload failed for "+f.name+": "+upError.message);break}
   const {data,error:e}=await supabase.from("dv_accounting_listing_documents").insert([{listing_id:selected.id,document_type:documentType,document_name:documentName,storage_path:path,mime_type:f.type||null,file_size:f.size,uploaded_by:user.id}]).select().single();
   if(e){await supabase.storage.from("dv-trade-documents").remove([path]);setError("Could not register "+f.name+": "+e.message);break}
   count++;setDocs(old=>[...old,data]);
  }
  if(count===uploadQueue.length){setFileBatch([]);setSplitPreview(null);setMessage(count+" listing document(s) uploaded.")}
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
 const canEdit=isAdmin||(!selected||["DRAFT","NEEDS_CHANGES"].includes(selected.status));
 const visibleRequirements=useMemo(()=>requirements,[requirements]);
 const inp=(key,caption,type="text",opts=null)=><label style={labelStyle}>{caption}{opts?<select disabled={!canEdit} style={fieldStyle} value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}>{opts.map(o=><option key={o[0]} value={o[0]}>{o[1]}</option>)}</select>:<input disabled={!canEdit} style={fieldStyle} type={type} value={form[key]??""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))} />}</label>;
 return <div style={{display:"grid",gap:14}}>
  <div className="pagehead"><div><h1>Listings</h1><p>Listing paperwork submission, compliance review, and REALM MLS tracking.</p></div><button className="primary" type="button" onClick={startNew}>{isAdmin?"+ Add Listing for Agent":"+ New Listing"}</button></div>
  {error&&<div className="notice" role="alert"><AlertCircle size={16}/> {error}</div>}{message&&<div className="notice" role="status"><CheckCircle2 size={16}/> {message}</div>}
  <div style={{display:"grid",gridTemplateColumns:isAdmin?"minmax(260px,0.8fr) minmax(0,1.6fr)":"1fr",gap:12,alignItems:"start"}}>
   <section className="panel" style={{padding:12}}><div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{isAdmin?"Listing Review Queue":"My Listings"}</h2><button className="secondary" type="button" onClick={load}><RefreshCw size={14}/></button></div>
    {loading?<p className="muted">Loading…</p>:!rows.length?<p className="muted">No listing submissions yet.</p>:<div style={{display:"grid",gap:6}}>{rows.map(row=><button type="button" key={row.id} onClick={()=>openListing(row)} style={{textAlign:"left",padding:9,border:"1px solid "+(selected?.id===row.id?"#9e8556":"#e4e7ec"),borderRadius:7,background:selected?.id===row.id?"#f8f5ee":"white",cursor:"pointer"}}><b style={{fontSize:13}}>{row.property_address}{row.unit_number?" #"+row.unit_number:""}</b><div className="muted" style={{fontSize:11}}>{row.city}, {row.province} · {statusLabel(row.status)}</div>{row.mls_number&&<div style={{fontSize:11}}>MLS: {row.mls_number}</div>}{isAdmin&&<div className="muted" style={{fontSize:11}}>Primary agent: {[agents.find(a=>a.id===row.agent_id)?.first_name,agents.find(a=>a.id===row.agent_id)?.last_name].filter(Boolean).join(" ")||row.agent_id}{Array.isArray(row.additional_agent_ids)&&row.additional_agent_ids.filter(id=>id!==row.agent_id).length?" · +"+row.additional_agent_ids.filter(id=>id!==row.agent_id).length+" more agent(s)":""}</div>}</button>)}</div>}
   </section>
   <section className="panel" style={{padding:12}}>
    {!selected&&!newListing?<div className="muted">{isAdmin?"Select a listing from the queue to review.":"Create a listing submission to begin."}</div>:<>
     <div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{selected?form.property_address||"Listing details":"New Listing Submission"}</h2>{selected&&<span className="pill">{statusLabel(selected.status)}</span>}</div>
     {isAdmin&&<label style={{...labelStyle,marginBottom:9}}>Primary / Responsible Agent *<AgentSearchSelect agents={agents} value={assignedAgentId} onChange={id=>{setAssignedAgentId(id);setAdditionalAgentIds(ids=>ids.filter(existing=>existing!==id))}}/></label>}<div style={{marginBottom:10}}><label style={labelStyle}>Additional Representing Agents (optional)<input style={fieldStyle} value={additionalAgentSearch} onChange={e=>setAdditionalAgentSearch(e.target.value)} placeholder="Search agents by name..."/><select multiple style={{...fieldStyle,minHeight:82}} value={additionalAgentIds} onChange={e=>setAdditionalAgentIds(Array.from(e.target.selectedOptions).map(o=>o.value).filter(id=>id!==(isAdmin?assignedAgentId:agentId)))}>{agents.filter(a=>a.id!==(isAdmin?assignedAgentId:agentId)&&([a.first_name,a.last_name,a.full_name,a.email,a.agent_number].filter(Boolean).join(" ").toLowerCase().includes(additionalAgentSearch.toLowerCase()))).map(a=><option key={a.id} value={a.id}>{[a.first_name,a.last_name].filter(Boolean).join(" ")||a.full_name||a.email||a.id}</option>)}</select><small className="muted">Search by name, then select one or more agents. Hold Ctrl (Windows) or Command (Mac) to select multiple matches.</small></label></div>
     <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:9}}>
      {inp("property_address","Property address *")}{inp("unit_number","Unit #")}{inp("city","City *")}{inp("province","Province", "text", [["ON","Ontario"],["AB","Alberta"],["BC","British Columbia"],["QC","Quebec"],["Other","Other"]])}{inp("postal_code","Postal code")}{inp("property_type","Property type","text",[["RESIDENTIAL","Residential"],["CONDO","Condo"],["COMMERCIAL","Commercial"],["LAND","Land"],["OTHER","Other"]])}{inp("listing_type","Listing type","text",[["SALE","For Sale"],["LEASE","For Lease"]])}{inp("asking_price","Asking price","number")}{inp("listing_start_date","Listing start date","date")}{inp("listing_expiry_date","Listing expiry date","date")}
     </div>
     <label style={{...labelStyle,marginTop:9}}>Notes / special instructions<textarea disabled={!canEdit} rows={3} style={fieldStyle} value={form.notes||""} onChange={e=>setForm(v=>({...v,notes:e.target.value}))}/></label>
     {canEdit&&<div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}><button className="secondary" type="button" disabled={busy} onClick={()=>saveDraft(false)}><Save size={14}/> Save Draft</button>{selected&&<button className="primary" type="button" disabled={busy} onClick={()=>saveDraft(true)}><Send size={14}/> Submit for Review</button>}</div>}
     {(selected||newListing)&&<div style={{marginTop:12,borderTop:"1px solid #eaecf0",paddingTop:10}}><h3 style={{fontSize:14,margin:"0 0 8px"}}>Listing Paperwork & Document Requirements</h3><label style={{display:"flex",alignItems:"center",gap:7,fontSize:12,margin:"0 0 8px",fontWeight:600}}><input type="checkbox" checked={autoSplit} onChange={e=>{setAutoSplit(e.target.checked);setSplitPreview(null);}}/> Auto-split combined PDF files and detect document types</label><p className="muted" style={{fontSize:11,margin:"0 0 8px"}}>{selected?"Upload each document against the configured Listing requirements below.":"Save the listing draft first to enable uploads. Your configured Listing requirements are shown now."}</p><div style={{display:"grid",gap:5}}>{visibleRequirements.map(r=>{const found=docs.filter(d=>d.document_type===r.code);return <div key={r.code} style={{display:"flex",gap:8,alignItems:"center",fontSize:12,padding:"5px 0",borderBottom:"1px solid #f2f4f7"}}><FileText size={14}/><span style={{flex:1}}>{r.label}{r.required?" *":""}</span><span className="muted">{found.length?"✓ "+found.length+" file(s)":"Not uploaded"}</span></div>})}</div>
      {canEdit&&<div style={{display:"grid",gridTemplateColumns:"minmax(150px,1fr) minmax(160px,1.4fr) auto",gap:7,alignItems:"end",marginTop:9}}><label style={labelStyle}>Document type<select style={fieldStyle} value={uploadType} onChange={e=>setUploadType(e.target.value)}>{requirements.map(r=><option key={r.code} value={r.code}>{r.label}</option>)}</select></label><label style={labelStyle}>Choose file(s)<input style={fieldStyle} type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" disabled={!selected&&!newListing} onChange={e=>{setFileBatch(Array.from(e.target.files||[]));setSplitPreview(null);setMessage("");}}/></label><button className="secondary" type="button" disabled={busy||splitting||!selected||!fileBatch.length||!requirements.length} onClick={uploadFiles}><Upload size={14}/>{splitting?"Splitting…":autoSplit?"Prepare / Split":"Upload"}</button></div>}
      {splitPreview&&<div style={{marginTop:10,padding:10,border:"1px solid #d0d5dd",borderRadius:7,display:"grid",gap:8}}><div><b style={{fontSize:13}}>Review split documents ({splitPreview.length})</b><p className="muted" style={{fontSize:11,margin:"3px 0 0"}}>Confirm each document type before uploading. Low-confidence matches need manual review.</p></div>{splitPreview.map((item,i)=><div key={i} style={{display:"grid",gridTemplateColumns:"minmax(0,1fr) minmax(150px,1fr) auto",gap:7,alignItems:"center"}}><span style={{fontSize:11,overflowWrap:"anywhere"}}>{item.document_name}<small className="muted" style={{display:"block"}}>Page(s): {item.pages}{item.needsReview?" · Review classification":""}</small></span><select style={fieldStyle} value={item.document_type} onChange={e=>setSplitPreview(old=>old.map((x,j)=>j===i?{...x,document_type:e.target.value,needsReview:false}:x))}>{requirements.map(r=><option key={r.code} value={r.code}>{r.label}</option>)}</select><button type="button" className="textbutton" onClick={()=>setSplitPreview(old=>old.filter((_,j)=>j!==i))}>Remove</button></div>)}<div style={{display:"flex",gap:7,flexWrap:"wrap"}}><button type="button" className="primary" disabled={busy||!splitPreview.length} onClick={uploadFiles}><Upload size={14}/> Upload reviewed documents</button><button type="button" className="secondary" onClick={()=>setSplitPreview(null)}>Cancel review</button></div></div>}
      {!requirements.length&&<p className="muted" style={{fontSize:12}}>No Listing-side document types are configured. Open Settings → Trade & Listing Documents Requirements → Listing and enable the document types.</p>}{docs.map(d=><div key={d.id} style={{display:"flex",alignItems:"center",gap:7,padding:"5px 0",fontSize:12}}><FileText size={14}/><span style={{flex:1}}>{d.document_name}<small className="muted" style={{display:"block"}}>{requirements.find(r=>r.code===d.document_type)?.label||d.document_type}</small></span><button type="button" className="textbutton" onClick={()=>openDocument(d)}>View</button></div>)}
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
