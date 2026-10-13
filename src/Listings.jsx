import {useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import AgentSearchSelect from "./AgentSearchSelect";
import {Upload,RefreshCw,CheckCircle2,AlertCircle,FileText,Send,Save,Building2,Trash2} from "lucide-react";
import { PDFDocument } from "pdf-lib";
import * as pdfjsLib from "pdfjs-dist/legacy/build/pdf.mjs";
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";
pdfjsLib.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

const blank={property_address:"",unit_number:"",city:"",province:"ON",postal_code:"",property_type:"RESIDENTIAL",listing_type:"SALE",asking_price:"",listing_start_date:"",listing_expiry_date:"",notes:""};
const defaults=[{code:"LISTING_AGREEMENT",label:"Listing Agreement",required:true},{code:"MLS_DATA",label:"MLS Data / Listing Information",required:true},{code:"PROPERTY_DETAILS",label:"Property Details / Feature Sheet",required:true},{code:"SELLER_DIRECTION",label:"Seller Direction / Authorization",required:true},{code:"ID_FINTRAC",label:"Identification / FINTRAC",required:true},{code:"OTHER",label:"Other Supporting Documents",required:false}];
const fieldStyle={width:"100%",boxSizing:"border-box",minHeight:36,padding:"7px 9px",border:"1px solid #d0d5dd",borderRadius:6};
const labelStyle={display:"grid",gap:4,fontSize:12,fontWeight:600};
const statusLabel=s=>({DRAFT:"Draft",SUBMITTED:"Awaiting review",NEEDS_CHANGES:"Changes requested",APPROVED:"Approved — awaiting MLS",APPROVED_WITH_CHANGES:"Approved with minor changes — awaiting MLS",PUBLISHED:"Published to MLS"}[s]||s||"—");
export default function Listings({user,agentId,adminMode=false,canDeleteDocuments=false}){
 const [rows,setRows]=useState([]),[docs,setDocs]=useState([]),[activeTab,setActiveTab]=useState("PROPERTY"),[selectedRequirementCode,setSelectedRequirementCode]=useState("LISTING_AGREEMENT"),[previewDocument,setPreviewDocument]=useState(null),[previewUrl,setPreviewUrl]=useState(""),[requirements,setRequirements]=useState(defaults),[companyId,setCompanyId]=useState(""),[agents,setAgents]=useState([]),[assignedAgentId,setAssignedAgentId]=useState(""),[additionalAgentIds,setAdditionalAgentIds]=useState([]),[additionalAgentSearch,setAdditionalAgentSearch]=useState(""),[selected,setSelected]=useState(null),[form,setForm]=useState({...blank}),[newListing,setNewListing]=useState(false),[uploadType,setUploadType]=useState(defaults[0].code),[fileBatch,setFileBatch]=useState([]),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[error,setError]=useState(""),[message,setMessage]=useState(""),[mlsNumber,setMlsNumber]=useState(""),[adminNotes,setAdminNotes]=useState(""),[autoSplit,setAutoSplit]=useState(false),[splitPreview,setSplitPreview]=useState(null),[splitting,setSplitting]=useState(false),[changeRequests,setChangeRequests]=useState([]),[requestText,setRequestText]=useState(""),[renamingDocumentId,setRenamingDocumentId]=useState(null),[documentNameDraft,setDocumentNameDraft]=useState(""),[fileNameDrafts,setFileNameDrafts]=useState([]);
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
   const configured=types.map(code=>{const normalizedCode=String(code);const found=master.find(x=>x.code===normalizedCode)||legacy.find(x=>String(x.code)===normalizedCode)||{code:normalizedCode,label:normalizedCode};return {...found,code:normalizedCode,label:normalizedCode==="OTHER"?"Other Supporting Documents":found.label};}).filter(x=>x.code);
   if(configured.length){const withOther=configured.some(x=>x.code==="OTHER")?configured:[...configured,{code:"OTHER",label:"Other Supporting Documents"}];setRequirements(withOther.map(x=>({...x,label:x.code==="OTHER"?"Other Supporting Documents":x.label,required:x.code==="OTHER"?false:required.includes(x.code)})));}
   else if(legacy.length){const withOther=legacy.filter(x=>x&&x.code&&x.label).map(x=>({code:String(x.code),label:String(x.code)==="OTHER"?"Other Supporting Documents":String(x.label),required:String(x.code)==="OTHER"?false:x.required!==false}));if(!withOther.some(x=>x.code==="OTHER"))withOther.push({code:"OTHER",label:"Other Supporting Documents",required:false});setRequirements(withOther);}
  }
  let q=supabase.from("dv_accounting_listing_submissions").select("*").order("created_at",{ascending:false});
  if(!isAdmin)q=q.eq("agent_id",agentId);
  const {data,error:e}=await q;
  if(e)setError("Could not load listing submissions: "+e.message);else setRows(data||[]);
  setLoading(false);
 },[isAdmin,agentId]);
 useEffect(()=>{load()},[load]);
 const loadDocs=useCallback(async(id)=>{if(!id){setDocs([]);return []}const {data,error:e}=await supabase.from("dv_accounting_listing_documents").select("*").eq("listing_id",id).order("created_at");if(e){setError(e.message);return []}const loaded=data||[];setDocs(loaded);return loaded},[]);
 function startNew(){setActiveTab("PROPERTY");setSelectedRequirementCode(requirements[0]?.code||"LISTING_AGREEMENT");setPreviewDocument(null);setPreviewUrl("");setSelected(null);setForm({...blank});setDocs([]);setNewListing(true);setFileBatch([]);setAssignedAgentId("");setAdditionalAgentIds([]);setAdditionalAgentSearch("");setMessage("");setError("");setMlsNumber("");setAdminNotes("");setChangeRequests([]);setRequestText("")}
 async function openListing(row){setActiveTab("PROPERTY");setSelectedRequirementCode(requirements[0]?.code||"LISTING_AGREEMENT");setPreviewDocument(null);setPreviewUrl("");setSelected(row);setForm({...blank,...row});setAssignedAgentId(row.agent_id||"");setAdditionalAgentIds(Array.isArray(row.additional_agent_ids)?row.additional_agent_ids.filter(id=>id!==row.agent_id):[]);setNewListing(false);setMlsNumber(row.mls_number||"");setAdminNotes(row.admin_notes||"");setRequestText("");setMessage("");setError("");const loadedDocs=await loadDocs(row.id);const firstUploaded=loadedDocs.find(d=>requirements.some(r=>r.code===d.document_type));if(firstUploaded)await openDocument(loadedDocs.filter(d=>d.document_type===firstUploaded.document_type).slice(-1)[0]);const {data,error:e}=await supabase.from("dv_accounting_listing_change_requests").select("*").eq("listing_id",row.id).order("created_at",{ascending:false});if(e)setError("Could not load change requests: "+e.message);else setChangeRequests(data||[])}
 async function saveDraft(submit=false){
  const targetAgentId=isAdmin?(assignedAgentId||selected?.agent_id):agentId;
  if(!targetAgentId){setError(isAdmin?"Select the agent this listing belongs to.":"Your login is not linked to an active agent profile.");return null}
  if(!String(form.property_address||"").trim()||!String(form.city||"").trim()){setError("Property address and city are required.");return null}
  if(submit&&!selected?.id){setError("Save the listing draft first, upload the paperwork, then submit it for review.");return null}
  if(submit){const missing=requirements.filter(r=>r.required&&!docs.some(d=>d.document_type===r.code));if(missing.length){setError("Upload required listing documents before submitting: "+missing.map(x=>x.label).join(", "));return null}}
  setBusy(true);setError("");setMessage("");
  try{
   if(!supabase)throw new Error("Database connection is unavailable. Refresh the page and sign in again.");
   const payload={property_address:String(form.property_address).trim(),additional_agent_ids:isAdmin?[...new Set([targetAgentId,...additionalAgentIds].filter(Boolean))]:[...new Set([agentId,...additionalAgentIds].filter(Boolean))],unit_number:form.unit_number||"",city:String(form.city).trim(),province:form.province||"ON",postal_code:form.postal_code||"",property_type:form.property_type||"RESIDENTIAL",listing_type:form.listing_type||"SALE",asking_price:form.asking_price?Number(form.asking_price):null,listing_start_date:form.listing_start_date||null,listing_expiry_date:form.listing_expiry_date||null,notes:form.notes||"",status:submit?"SUBMITTED":(selected?.status==="NEEDS_CHANGES"?"NEEDS_CHANGES":"DRAFT"),updated_at:new Date().toISOString()};
   let result;
   if(selected?.id)result=await supabase.from("dv_accounting_listing_submissions").update({...payload,...(isAdmin?{agent_id:targetAgentId}:{})}).eq("id",selected.id).select().single();
   else result=await supabase.from("dv_accounting_listing_submissions").insert([{...payload,agent_id:targetAgentId,company_id:companyId||null,created_by:user?.id||null}]).select().single();
   if(result.error)throw new Error("Could not save listing: "+result.error.message);
   const saved=result.data;
   setSelected(saved);setAssignedAgentId(saved.agent_id||targetAgentId);setAdditionalAgentIds(Array.isArray(saved.additional_agent_ids)?saved.additional_agent_ids.filter(id=>id!==saved.agent_id):[]);setForm({...blank,...saved});setNewListing(false);
   setMessage(submit?"Listing paperwork submitted for admin review.":"Listing draft saved.");
   await load();
   await loadDocs(saved.id);
   return saved;
  }catch(e){
   setError(e?.message||"Could not save the listing. Please try again.");
   return null;
  }finally{setBusy(false)}
 }
 async function prepareSplitPreview(){
  if(!fileBatch.length){setError("Choose one or more files first.");return}
  const pdfs=fileBatch.filter(f=>f.type==="application/pdf"||/\.pdf$/i.test(f.name));
  if(!pdfs.length){setError("Auto-splitting works with PDF files. Turn it off to upload other file types normally.");return}
  setSplitting(true);setError("");setMessage("");setSplitPreview(null);
  try{
   const prepared=[];
   for(const file of fileBatch){
    if(!(file.type==="application/pdf"||/\.pdf$/i.test(file.name))){prepared.push({file,document_type:uploadType,document_name:file.name,pages:"Original file",needsReview:false});continue}
    const bytes=await file.arrayBuffer();
    const loaded=await PDFDocument.load(bytes);
    let pageTypes=[];
    try{
     const pdf=await pdfjsLib.getDocument({data:bytes.slice(0)}).promise;
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
    }catch(readError){
     // Scanned/image-only PDFs may not have extractable text or the PDF.js worker may be unavailable.
     // Still split the PDF into individual pages so the user can assign each page manually.
     pageTypes=Array.from({length:loaded.getPageCount()},(_,i)=>({pageNo:i+1,code:uploadType,score:0,forceSeparate:true}));
    }
    const groups=[];
    for(const item of pageTypes){
     const last=groups[groups.length-1];
     if(last&&last.code===item.code&&!item.forceSeparate&&!last.forceSeparate){last.pages.push(item.pageNo);last.lowConfidence=last.lowConfidence||item.score<2}
     else groups.push({code:item.code,pages:[item.pageNo],lowConfidence:item.score<2,forceSeparate:!!item.forceSeparate});
    }
    const base=file.name.replace(/\.pdf$/i,"");
    for(const group of groups){
     const output=await PDFDocument.create();
     const copied=await output.copyPages(loaded,group.pages.map(p=>p-1));copied.forEach(p=>output.addPage(p));
     const blob=new Blob([await output.save()],{type:"application/pdf"});
     const label=requirements.find(r=>r.code===group.code)?.label||group.code;
     prepared.push({file:new File([blob],base+" - "+label+" - pages "+group.pages.join(",")+".pdf",{type:"application/pdf"}),sourceFile:file,totalPages:loaded.getPageCount(),startPage:Math.min(...group.pages),endPage:Math.max(...group.pages),document_type:group.code,document_name:base+" - "+label+" - pages "+group.pages.join(",")+".pdf",pages:group.pages.join(", "),needsReview:group.lowConfidence});
    }
   }
   if(!prepared.length)throw new Error("No documents were produced from the selected files.");
   setSplitPreview(prepared);
   setMessage("Split preview ready. Review document types, then click Upload reviewed documents. Scanned pages are separated individually for manual classification.");
  }catch(e){setError("Could not split this PDF: "+(e?.message||String(e)));}
  finally{setSplitting(false)}
 }
 async function uploadFiles(){
  if((!selected?.id&&!newListing)||(!fileBatch.length&&!splitPreview?.length)){setError("Select one or more files first.");return}
  if(!user?.id){setError("Your login session is missing. Sign in again before uploading files.");return}
  let listing=selected;
  if(!listing?.id){listing=await saveDraft(false);if(!listing?.id)return}
  if(autoSplit&&!splitPreview&&fileBatch.some(f=>f.type==="application/pdf"||/\.pdf$/i.test(f.name))){await prepareSplitPreview();return}
  setBusy(true);setError("");setMessage("");
  const uploadQueue=splitPreview?.length?splitPreview:fileBatch.map((file,i)=>{const customName=uploadType==="OTHER"?String(fileNameDrafts[i]||"").trim():"";const ext=(file.name.match(/\\.[^.]+$/)||[])[0]||"";const displayName=customName?( /\\.[^.]+$/.test(customName)?customName:customName+ext):file.name;return {file,document_type:uploadType,document_name:displayName};});
  let count=0;
  try{
   if(!supabase)throw new Error("The database connection is unavailable. Please refresh and sign in again.");
   for(const item of uploadQueue){
    let f=item.file;
    let documentType=item.document_type||uploadType;
    let documentName=item.document_name||f.name;
    if(item.sourceFile&&Number.isFinite(Number(item.startPage))&&Number.isFinite(Number(item.endPage))){
     const start=Math.floor(Number(item.startPage)),end=Math.floor(Number(item.endPage));
     if(start<1||end<start||end>item.totalPages)throw new Error("Invalid page range for "+documentName+". Choose pages between 1 and "+item.totalPages+".");
     const source=await PDFDocument.load(await item.sourceFile.arrayBuffer());
     const output=await PDFDocument.create();
     const copied=await output.copyPages(source,Array.from({length:end-start+1},(_,i)=>start-1+i));copied.forEach(p=>output.addPage(p));
     const base=item.sourceFile.name.replace(/\\.pdf$/i,"");
     const typeLabel=requirements.find(r=>r.code===documentType)?.label||documentType;
     documentName=base+" - "+typeLabel+" - pages "+start+"-"+end+".pdf";
     f=new File([await output.save()],documentName,{type:"application/pdf"});
    }
    const safe=f.name.replace(/[^a-zA-Z0-9._-]/g,"_");
    const path="listings/"+listing.id+"/"+String(user.id)+"/"+Date.now()+"-"+count+"-"+safe;
    const {error:upError}=await supabase.storage.from("dv-trade-documents").upload(path,f,{upsert:false,contentType:f.type||"application/octet-stream"});
    if(upError)throw new Error("Storage upload failed for "+f.name+": "+upError.message);
    const {data,error:e}=await supabase.from("dv_accounting_listing_documents").insert([{listing_id:listing.id,document_type:documentType,document_name:documentName,storage_path:path,mime_type:f.type||null,file_size:f.size,uploaded_by:user.id}]).select().single();
    if(e){await supabase.storage.from("dv-trade-documents").remove([path]);throw new Error("File uploaded but could not register "+f.name+": "+e.message);}
    count++;setDocs(old=>[...old,data]);
   }
   setFileBatch([]);setFileNameDrafts([]);setSplitPreview(null);setMessage(count+" listing document(s) uploaded successfully.");
  }catch(e){setError(e?.message||"Upload failed. Please try again.");}
  finally{setBusy(false);await loadDocs(listing.id);}
 }
 async function saveDocumentName(doc){
  const name=String(documentNameDraft||"").trim();
  if(!name){setError("Enter a name for this document.");return}
  if(!doc?.id)return;
  setBusy(true);setError("");setMessage("");
  const {data,error:e}=await supabase.from("dv_accounting_listing_documents").update({document_name:name}).eq("id",doc.id).select().single();
  if(e){setError("Could not rename document: "+e.message);setBusy(false);return}
  setDocs(old=>old.map(d=>d.id===doc.id?data:d));
  if(previewDocument?.id===doc.id)setPreviewDocument(data);
  setRenamingDocumentId(null);setDocumentNameDraft("");setMessage("Document name updated.");setBusy(false);
 }
 async function adminUpdate(status){
  if(!selected?.id)return;
  if(["APPROVED","APPROVED_WITH_CHANGES"].includes(status)){const missing=requirements.filter(r=>r.required&&!docs.some(d=>d.document_type===r.code));if(missing.length){setError("Cannot approve until required listing documents are uploaded: "+missing.map(x=>x.label).join(", "));return}}
  if(status==="PUBLISHED"&&!String(mlsNumber||"").trim()){setError("Enter the MLS number after the listing has been entered into REALM MLS.");return}
  if(status==="APPROVED_WITH_CHANGES"&&!String(adminNotes||"").trim()){setError("Add the minor changes required in Review notes before approving with minor changes.");return}
  if(status==="PUBLISHED"&&!selected?.status?.match(/APPROVED|PUBLISHED/)){setError("Approve the paperwork before marking the listing published.");return}
  setBusy(true);setError("");setMessage("");
  const {data,error:e}=await supabase.from("dv_accounting_listing_submissions").update({status,mls_number:status==="PUBLISHED"?mlsNumber.trim():(selected.mls_number||null),admin_notes:adminNotes,reviewed_by:user?.id||null,reviewed_at:new Date().toISOString(),published_at:status==="PUBLISHED"?new Date().toISOString():selected.published_at||null,updated_at:new Date().toISOString()}).eq("id",selected.id).select().single();
  if(e){setError("Could not update listing: "+e.message);setBusy(false);return}
  setSelected(data);setForm({...blank,...data});setMlsNumber(data.mls_number||"");setMessage(status==="NEEDS_CHANGES"?"Changes requested; the agent can update the paperwork and resubmit.":status==="APPROVED"?"Paperwork approved. This listing is now assigned to the admin team to enter into REALM MLS. After REALM assigns the MLS number, enter it below and mark the listing Published.":status==="APPROVED_WITH_CHANGES"?"Paperwork approved with minor changes noted. The listing may proceed to REALM MLS; complete the noted corrections as required.":"Listing marked as published with MLS number "+data.mls_number+".");
  await load();setBusy(false);
 }
 async function openDocument(d){setError("");setSelectedRequirementCode(d.document_type);const {data,error:e}=await supabase.storage.from("dv-trade-documents").createSignedUrl(d.storage_path,3600);if(e){setError("Could not preview document: "+e.message);return}setPreviewDocument(d);setPreviewUrl(data.signedUrl);setActiveTab("DOCUMENTS")}
 async function deleteListingDocument(d){if(!canDeleteDocuments||!d?.id||!supabase)return;if(!window.confirm("Permanently delete this listing document? This cannot be undone. Confirm the file is not required for an active compliance or retention obligation."))return;setBusy(true);setError("");setMessage("");try{const{error:rowError}=await supabase.from("dv_accounting_listing_documents").delete().eq("id",d.id);if(rowError)throw new Error("Could not remove the document register entry: "+rowError.message);const{error:storageError}=await supabase.storage.from("dv-trade-documents").remove([d.storage_path]);if(storageError){setError("The document register entry was deleted, but the stored file could not be removed: "+storageError.message);await loadDocs(selected?.id);return}setDocs(old=>old.filter(x=>x.id!==d.id));if(previewDocument?.id===d.id){setPreviewDocument(null);setPreviewUrl("")}setMessage("Listing document deleted.");}catch(e){setError(e?.message||"Could not delete the listing document.")}finally{setBusy(false)}}
 const canEdit=isAdmin||(!selected||["DRAFT","NEEDS_CHANGES"].includes(selected.status));
 const canUploadDocs=isAdmin||!selected||!!selected.id;
 async function submitChangeRequest(){if(!selected?.id||!String(requestText||"").trim()){setError("Describe the listing change you want the admin team to make.");return}setBusy(true);setError("");setMessage("");const {data,error:e}=await supabase.from("dv_accounting_listing_change_requests").insert([{listing_id:selected.id,requested_by:user?.id,request_text:requestText.trim()}]).select().single();if(e)setError("Could not send change request: "+e.message);else{setChangeRequests(old=>[data,...old]);setRequestText("");setMessage("Your change request has been sent to the admin team. The approved listing details remain locked.")}setBusy(false)}
 async function completeChangeRequest(item){setBusy(true);setError("");const {data,error:e}=await supabase.from("dv_accounting_listing_change_requests").update({status:"COMPLETED",reviewed_by:user?.id||null,reviewed_at:new Date().toISOString()}).eq("id",item.id).select().single();if(e)setError("Could not update request: "+e.message);else{setChangeRequests(old=>old.map(x=>x.id===item.id?data:x));setMessage("Change request marked as handled.")}setBusy(false)}
 const visibleRequirements=useMemo(()=>requirements.filter(r=>r.code==="OTHER"||docs.some(d=>d.document_type===r.code)),[requirements,docs]);
 const inp=(key,caption,type="text",opts=null)=><label style={labelStyle}>{caption}{opts?<select disabled={!canEdit} style={fieldStyle} value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}>{opts.map(o=><option key={o[0]} value={o[0]}>{o[1]}</option>)}</select>:<input disabled={!canEdit} style={fieldStyle} type={type} value={form[key]??""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))} />}</label>;
 return <div style={{display:"grid",gap:14}}>
  <div className="pagehead"><div><h1>{selected||newListing?(selected?(form.property_address||"Listing Details"):"Add Listing"):"Listings"}</h1><p>{selected||newListing?"Manage property details, required paperwork, and listing review in the full workspace.":"Listing paperwork submission, compliance review, and REALM MLS tracking."}</p></div><div style={{display:"flex",gap:8,flexWrap:"wrap"}}>{(selected||newListing)&&<button className="secondary" type="button" onClick={()=>{setSelected(null);setNewListing(false);setDocs([]);setPreviewDocument(null);setPreviewUrl("");setFileBatch([]);setSplitPreview(null);setError("");setMessage("");}}>← Back to Listings</button>}{!(selected||newListing)&&<button className="primary" type="button" onClick={startNew}>{isAdmin?"+ Add Listing for Agent":"+ Add Listing"}</button>}</div></div>
  {error&&<div className="notice" role="alert"><AlertCircle size={16}/> {error}</div>}{message&&<div className="notice" role="status"><CheckCircle2 size={16}/> {message}</div>}
  <div className={"listing-page-workspace "+((selected||newListing)?"listing-page-detail":"listing-page-list")}>
   {!(selected||newListing)&&<section className="panel listing-list-panel" style={{padding:12}}><div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{isAdmin?"Listing Review Queue":"My Listings"}</h2><button className="secondary" type="button" onClick={load}><RefreshCw size={14}/> Refresh</button></div>
    {loading?<p className="muted" style={{padding:"8px 2px",margin:0}}>Loading listings…</p>:!rows.length?<p className="muted" style={{padding:"8px 2px",margin:0}}>No listing submissions yet.</p>:<div style={{display:"grid",gap:3}}>{rows.map(row=>{const primaryAgent=agents.find(a=>a.id===row.agent_id);const extraAgents=Array.isArray(row.additional_agent_ids)?row.additional_agent_ids.filter(id=>id!==row.agent_id).length:0;return <button type="button" key={row.id} onClick={()=>openListing(row)} style={{display:"flex",alignItems:"center",justifyContent:"space-between",flexWrap:"wrap",gap:"4px 12px",textAlign:"left",padding:"6px 9px",border:"1px solid "+(selected?.id===row.id?"#9e8556":"#e4e7ec"),borderRadius:5,background:selected?.id===row.id?"#f8f5ee":"white",cursor:"pointer",minWidth:0}}><span style={{display:"flex",alignItems:"baseline",flexWrap:"wrap",gap:"2px 9px",flex:"1 1 250px",minWidth:0}}><b style={{fontSize:13,lineHeight:1.3,overflowWrap:"anywhere"}}>{row.property_address}{row.unit_number?" #"+row.unit_number:""}</b><span className="muted" style={{fontSize:11}}>{[row.city,row.province].filter(Boolean).join(", ")}</span></span><span style={{display:"flex",alignItems:"center",flexWrap:"wrap",gap:"3px 10px",fontSize:11}}>{row.asking_price!=null&&row.asking_price!==""&&<b style={{fontSize:12,color:"#0f2141"}}>{Number(row.asking_price).toLocaleString("en-CA",{style:"currency",currency:"CAD",maximumFractionDigits:0})}</b>}<span className="muted">{[String(row.listing_type||"").toUpperCase()==="LEASE"?"Lease":"Sale",String(row.property_type||"").replaceAll("_"," ").toLowerCase().replace(/^./,c=>c.toUpperCase())].filter(Boolean).join(" · ")}</span>{row.mls_number&&<span>MLS {row.mls_number}</span>}{isAdmin&&<span className="muted" style={{maxWidth:220,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}} title={"Primary agent: "+([primaryAgent?.first_name,primaryAgent?.last_name].filter(Boolean).join(" ")||row.agent_id)}>{[primaryAgent?.first_name,primaryAgent?.last_name].filter(Boolean).join(" ")||"Agent not found"}{extraAgents?" +"+extraAgents:""}</span>}</span><span style={{fontSize:10,fontWeight:700,whiteSpace:"normal",padding:"4px 7px",borderRadius:4,border:"1px solid "+(row.status==="APPROVED_WITH_CHANGES"||(row.status==="PUBLISHED"&&!!String(row.admin_notes||"").trim())?"#d97706":"#e4e7ec"),background:(row.status==="APPROVED_WITH_CHANGES"||(row.status==="PUBLISHED"&&!!String(row.admin_notes||"").trim()))?"#fffaeb":"#f8fafc",color:(row.status==="APPROVED_WITH_CHANGES"||(row.status==="PUBLISHED"&&!!String(row.admin_notes||"").trim()))?"#92400e":"#344054"}}>{row.status==="APPROVED_WITH_CHANGES"||(row.status==="PUBLISHED"&&!!String(row.admin_notes||"").trim())?"⚠ Minor changes — review":statusLabel(row.status)}</span>{isAdmin&&(row.status==="APPROVED_WITH_CHANGES"||(row.status==="PUBLISHED"&&!!String(row.admin_notes||"").trim()))&&<span style={{flex:"1 0 100%",boxSizing:"border-box",marginTop:3,padding:"8px 10px",borderRadius:5,border:"2px solid #fdb022",background:"#fffaeb",color:"#92400e",fontSize:12,whiteSpace:"normal",overflowWrap:"anywhere"}}><b>⚠ ADMIN ATTENTION — MINOR CHANGES REQUIRED</b><div style={{marginTop:3}}>{String(row.admin_notes||"No concern details entered. Open listing and add review notes.").trim()}</div></span>}</button>})}</div>}
   </section>}
   {(selected||newListing)&&<section className="panel listing-detail-panel" style={{padding:16}}>
    <>
     <div className="paneltitle"><h2 style={{fontSize:16,margin:0}}>{selected?form.property_address||"Listing details":"New Listing Submission"}</h2>{selected&&<span className="pill">{statusLabel(selected.status)}</span>}</div>
     <div className="listing-detail-tabs" role="tablist" aria-label="Listing details"><button type="button" role="tab" aria-selected={activeTab==="PROPERTY"} className={activeTab==="PROPERTY"?"active":""} onClick={()=>setActiveTab("PROPERTY")}><Building2 size={15}/> Property Information</button><button type="button" role="tab" aria-selected={activeTab==="DOCUMENTS"} className={activeTab==="DOCUMENTS"?"active":""} onClick={()=>setActiveTab("DOCUMENTS")}><FileText size={15}/> Documents <span className="listing-tab-count">{docs.length}</span></button></div>
     {activeTab==="PROPERTY"&&<div className="listing-property-tab">
     {isAdmin&&<label style={{...labelStyle,marginBottom:9}}>Primary / Responsible Agent *<AgentSearchSelect agents={agents} value={assignedAgentId} onChange={id=>{setAssignedAgentId(id);setAdditionalAgentIds(ids=>ids.filter(existing=>existing!==id))}}/></label>}<div style={{marginBottom:10}}><label style={labelStyle}>Additional Representing Agents (optional)<input style={fieldStyle} value={additionalAgentSearch} onChange={e=>setAdditionalAgentSearch(e.target.value)} placeholder="Search agents by name..."/><select multiple style={{...fieldStyle,minHeight:82}} value={additionalAgentIds} onChange={e=>setAdditionalAgentIds(Array.from(e.target.selectedOptions).map(o=>o.value).filter(id=>id!==(isAdmin?assignedAgentId:agentId)))}>{agents.filter(a=>a.id!==(isAdmin?assignedAgentId:agentId)&&([a.first_name,a.last_name,a.full_name,a.email,a.agent_number].filter(Boolean).join(" ").toLowerCase().includes(additionalAgentSearch.toLowerCase()))).map(a=><option key={a.id} value={a.id}>{[a.first_name,a.last_name].filter(Boolean).join(" ")||a.full_name||a.email||a.id}</option>)}</select><small className="muted">Search by name, then select one or more agents. Hold Ctrl (Windows) or Command (Mac) to select multiple matches.</small></label></div>
     <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))",gap:9}}>
      {inp("property_address","Property address *")}{inp("unit_number","Unit #")}{inp("city","City *")}{inp("province","Province", "text", [["ON","Ontario"],["AB","Alberta"],["BC","British Columbia"],["QC","Quebec"],["Other","Other"]])}{inp("postal_code","Postal code")}{inp("property_type","Property type","text",[["RESIDENTIAL","Residential"],["CONDO","Condo"],["COMMERCIAL","Commercial"],["LAND","Land"],["OTHER","Other"]])}{inp("listing_type","Listing type","text",[["SALE","For Sale"],["LEASE","For Lease"]])}{inp("asking_price","Asking price","number")}{inp("listing_start_date","Listing start date","date")}{inp("listing_expiry_date","Listing expiry date","date")}
     </div>
     <label style={{...labelStyle,marginTop:9}}>Notes / special instructions<textarea disabled={!canEdit} rows={3} style={fieldStyle} value={form.notes||""} onChange={e=>setForm(v=>({...v,notes:e.target.value}))}/></label>
     {canEdit&&<div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}><button className="secondary" type="button" disabled={busy} onClick={()=>saveDraft(false)}><Save size={14}/> Save Draft</button>{selected&&<button className="primary" type="button" disabled={busy} onClick={()=>saveDraft(true)}><Send size={14}/> Submit for Review</button>}</div>}
     </div>}
     {activeTab==="DOCUMENTS"&&(selected||newListing)&&<div className="listing-documents-tab"><div style={{marginTop:8,paddingTop:4}}><h3 style={{fontSize:15,margin:"0 0 8px"}}>Documents & Requirements</h3><label style={{display:"flex",alignItems:"center",gap:7,fontSize:12,margin:"0 0 8px",fontWeight:600}}><input type="checkbox" checked={autoSplit} onChange={e=>{setAutoSplit(e.target.checked);setSplitPreview(null);}}/> Auto-split combined PDF files and detect document types</label><p className="muted" style={{fontSize:11,margin:"0 0 8px"}}>{selected?"Upload each document against the configured Listing requirements below.":"Your first upload automatically saves this listing as a draft, then uploads the paperwork. Enter the required property details and agent first."}</p><div className="listing-requirement-preview-workspace">
       <div className="listing-requirement-list" aria-label="Uploaded listing documents">{visibleRequirements.length?visibleRequirements.map(r=>{return <button key={r.code} type="button" className={"listing-requirement-item"+(selectedRequirementCode===r.code?" active":"")} onClick={()=>{setSelectedRequirementCode(r.code);const match=docs.filter(d=>d.document_type===r.code).slice(-1)[0];if(match)openDocument(match);}} aria-pressed={selectedRequirementCode===r.code}><FileText size={16}/><span className="listing-requirement-label">{r.label}{r.required?" *":""}</span><span className="listing-requirement-status uploaded">{docs.filter(d=>d.document_type===r.code).length} file{docs.filter(d=>d.document_type===r.code).length===1?"":"s"}</span></button>}):<div className="listing-requirement-preview-empty"><FileText size={30}/><strong>No documents uploaded yet</strong><span>Only document types with uploaded files appear here. Use the upload controls below to add paperwork.</span></div>}</div>
       <div className="listing-requirement-preview-pane">
        <div className="listing-requirement-preview-heading"><div><strong>{visibleRequirements.find(r=>r.code===selectedRequirementCode)?.label||"Document Preview"}</strong><span>{docs.some(d=>d.document_type===selectedRequirementCode)?"Uploaded document preview":"Required document preview"}</span></div>{previewDocument&&previewDocument.document_type===selectedRequirementCode&&previewUrl&&<><a className="secondary listing-preview-open-link" href={previewUrl} target="_blank" rel="noreferrer">Open in new tab</a>{canDeleteDocuments&&<button type="button" className="textbutton danger" disabled={busy} onClick={()=>deleteListingDocument(previewDocument)}><Trash2 size={14}/> Delete document</button>}</>}</div>
        {previewDocument&&previewDocument.document_type===selectedRequirementCode&&previewUrl?(((previewDocument.mime_type||"").toLowerCase().includes("pdf")||/\.pdf$/i.test(previewDocument.document_name||""))?<iframe title={"Preview "+(visibleRequirements.find(r=>r.code===selectedRequirementCode)?.label||"listing document")} src={previewUrl+"#toolbar=1&navpanes=0&view=FitH"} className="listing-document-preview-frame"/>:((previewDocument.mime_type||"").toLowerCase().startsWith("image/")||/\.(png|jpe?g|gif|webp|tiff?)$/i.test(previewDocument.document_name||""))?<img src={previewUrl} alt={visibleRequirements.find(r=>r.code===selectedRequirementCode)?.label||"Listing document"} className="listing-document-preview-image"/>:<div className="listing-document-preview-other"><FileText size={30}/><p>Preview is not available for this file type.</p><a href={previewUrl} target="_blank" rel="noreferrer">Open document in a new tab</a></div>):<div className="listing-requirement-preview-empty"><FileText size={36}/><strong>{docs.some(d=>d.document_type===selectedRequirementCode)?"Select the requirement again to load its preview":"No document uploaded for this requirement"}</strong><span>{docs.some(d=>d.document_type===selectedRequirementCode)?"Click this document requirement to preview the uploaded file here.":"Upload the corresponding form below. Uploaded filenames are kept out of this view."}</span></div>}
       </div>
      </div>
      {docs.some(d=>d.document_type===selectedRequirementCode)&&<div className="listing-category-files" style={{marginTop:10,padding:10,border:"1px solid var(--border,#d0d5dd)",borderRadius:8}}>
       <strong style={{fontSize:12}}>Files in this category ({docs.filter(d=>d.document_type===selectedRequirementCode).length})</strong>
       <div style={{display:"grid",gap:6,marginTop:7}}>
        {docs.filter(d=>d.document_type===selectedRequirementCode).map((d,index)=><div key={d.id} style={{display:"grid",gridTemplateColumns:"minmax(0,1fr) auto",alignItems:"center",gap:8,padding:"7px 8px",borderRadius:6,background:previewDocument?.id===d.id?"var(--surface-alt,#f2f4f7)":"transparent",border:"1px solid var(--border,#e4e7ec)"}}>
         <div style={{minWidth:0}}>
          {renamingDocumentId===d.id?<div style={{display:"flex",gap:6,alignItems:"center"}}><input aria-label="Document display name" style={{...fieldStyle,minWidth:0}} value={documentNameDraft} onChange={e=>setDocumentNameDraft(e.target.value)} maxLength={180} onKeyDown={e=>{if(e.key==="Enter"){e.preventDefault();saveDocumentName(d)}if(e.key==="Escape"){setRenamingDocumentId(null);setDocumentNameDraft("")}}}/><button type="button" className="primary" disabled={busy||!documentNameDraft.trim()} onClick={()=>saveDocumentName(d)}>Save</button><button type="button" className="secondary" onClick={()=>{setRenamingDocumentId(null);setDocumentNameDraft("")}}>Cancel</button></div>:<button type="button" onClick={()=>openDocument(d)} style={{display:"flex",alignItems:"center",gap:7,minWidth:0,width:"100%",border:0,padding:0,background:"transparent",color:"var(--navy)",textAlign:"left",cursor:"pointer"}}><FileText size={15}/><span style={{minWidth:0,overflowWrap:"anywhere",fontSize:12}}>{d.document_name||("Document "+(index+1))}<small className="muted" style={{display:"block"}}>{d.created_at?new Date(d.created_at).toLocaleString():""}</small></span></button>}
         </div>
         <div style={{display:"flex",alignItems:"center",gap:6}}>{canUploadDocs&&renamingDocumentId!==d.id&&<button type="button" className="textbutton" disabled={busy} onClick={()=>{setRenamingDocumentId(d.id);setDocumentNameDraft(d.document_name||"")}}>Rename</button>}{canDeleteDocuments&&<button type="button" className="textbutton danger" disabled={busy} onClick={()=>deleteListingDocument(d)}><Trash2 size={13}/> Delete</button>}</div>
        </div>)}
       </div>
      </div>}
      {canUploadDocs&&<div style={{display:"grid",gridTemplateColumns:"minmax(150px,1fr) minmax(160px,1.4fr) auto",gap:7,alignItems:"end",marginTop:9}}><label style={labelStyle}>Document type<select style={fieldStyle} value={uploadType} onChange={e=>setUploadType(e.target.value)}>{requirements.map(r=><option key={r.code} value={r.code}>{r.label}</option>)}</select></label><label style={labelStyle}>Choose file(s)<input style={fieldStyle} type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" disabled={!selected&&!newListing} onChange={e=>{const files=Array.from(e.target.files||[]);setFileBatch(files);setFileNameDrafts(files.map(f=>f.name.replace(/\\.[^.]+$/,"")));setSplitPreview(null);setMessage("");}}/></label><button className="secondary" type="button" disabled={busy||splitting||!fileBatch.length||!requirements.length} onClick={uploadFiles}><Upload size={14}/>{splitting?"Splitting…":!selected?(autoSplit?"Save & Prepare Split":"Save & Upload"):autoSplit?"Prepare / Split":"Upload"}</button></div>}
      {canUploadDocs&&uploadType==="OTHER"&&fileBatch.length>0&&!splitPreview&&<div style={{marginTop:9,padding:10,border:"1px solid #d0d5dd",borderRadius:7,display:"grid",gap:8}}><strong style={{fontSize:12}}>Name each supporting document before upload</strong><p className="muted" style={{fontSize:11,margin:0}}>These names will appear in the listing document list. The original file contents are not changed.</p>{fileBatch.map((file,i)=><label key={i} style={labelStyle}>{file.name}<input style={fieldStyle} value={fileNameDrafts[i]??file.name.replace(/\\.[^.]+$/,"")} maxLength={180} onChange={e=>setFileNameDrafts(old=>fileBatch.map((_,j)=>j===i?e.target.value:(old[j]??fileBatch[j].name.replace(/\\.[^.]+$/,""))))} placeholder="Enter a document name"/></label>)}</div>}
      {splitPreview&&<div style={{marginTop:10,padding:10,border:"1px solid #d0d5dd",borderRadius:7,display:"grid",gap:8}}><div><b style={{fontSize:13}}>Review split documents ({splitPreview.length})</b><p className="muted" style={{fontSize:11,margin:"3px 0 0"}}>Confirm each document type before uploading. Low-confidence matches need manual review.</p></div>{splitPreview.map((item,i)=><div key={i} style={{display:"grid",gridTemplateColumns:"minmax(0,1.2fr) minmax(150px,1fr) minmax(145px,0.8fr) auto",gap:7,alignItems:"end"}}><span style={{fontSize:11,overflowWrap:"anywhere"}}>{item.document_name}<small className="muted" style={{display:"block"}}>{item.sourceFile?"Choose page range (1–"+item.totalPages+")":"Page(s): "+item.pages}{item.needsReview?" · Review classification":""}</small></span><select aria-label={"Document type for "+item.document_name} style={fieldStyle} value={item.document_type} onChange={e=>setSplitPreview(old=>old.map((x,j)=>j===i?{...x,document_type:e.target.value,needsReview:false}:x))}>{requirements.map(r=><option key={r.code} value={r.code}>{r.label}</option>)}</select>{item.sourceFile?<div style={{display:"flex",gap:5}}><label style={labelStyle}>From<input aria-label={"First page for "+item.document_name} type="number" min="1" max={item.totalPages} style={fieldStyle} value={item.startPage} onChange={e=>setSplitPreview(old=>old.map((x,j)=>j===i?{...x,startPage:e.target.value,pages:e.target.value+"–"+x.endPage}:x))}/></label><label style={labelStyle}>To<input aria-label={"Last page for "+item.document_name} type="number" min="1" max={item.totalPages} style={fieldStyle} value={item.endPage} onChange={e=>setSplitPreview(old=>old.map((x,j)=>j===i?{...x,endPage:e.target.value,pages:x.startPage+"–"+e.target.value}:x))}/></label></div>:<span/>}<button type="button" className="textbutton" onClick={()=>setSplitPreview(old=>old.filter((_,j)=>j!==i))}>Remove</button></div>)}<div style={{display:"flex",gap:7,flexWrap:"wrap"}}><button type="button" className="secondary" onClick={()=>{const source=splitPreview.find(x=>x.sourceFile);if(!source)return;const name=source.sourceFile.name.replace(/\.pdf$/i,"")+" - pages 1-1.pdf";setSplitPreview(old=>[...old,{...source,file:new File([source.file],name,{type:"application/pdf"}),document_name:name,startPage:1,endPage:1,pages:"1–1",document_type:uploadType,needsReview:true}])}}>+ Add document page range</button><button type="button" className="primary" disabled={busy||!splitPreview.length} onClick={uploadFiles}><Upload size={14}/> Upload reviewed documents</button><button type="button" className="secondary" onClick={()=>setSplitPreview(null)}>Cancel review</button></div></div>}
      {!requirements.length&&<p className="muted" style={{fontSize:12}}>No Listing-side document types are configured. Open Settings → Trade & Listing Documents Requirements → Listing and enable the document types.</p>}
      
     </div></div>}
     {activeTab==="PROPERTY"&&<div className="listing-property-tab-secondary">
     {!isAdmin&&selected&&["APPROVED","APPROVED_WITH_CHANGES","PUBLISHED"].includes(selected.status)&&<div style={{marginTop:14,paddingTop:12,borderTop:"1px solid #eaecf0"}}><h3 style={{fontSize:14,margin:"0 0 6px"}}>Request a Listing Change</h3><p className="muted" style={{fontSize:11,margin:"0 0 8px"}}>Approved listing details are locked. If a correction or change is needed, send a request to the admin team. You can still upload supporting documents above using the configured document types, such as a price change amendment, suspension, or cancellation.</p><label style={labelStyle}>Describe the requested change<textarea rows={3} style={fieldStyle} value={requestText} onChange={e=>setRequestText(e.target.value)} placeholder="Explain what needs to be changed and why..."/></label><button type="button" className="primary" disabled={busy||!requestText.trim()} style={{marginTop:8}} onClick={submitChangeRequest}>Send Change Request to Admin</button>{changeRequests.length>0&&<div style={{display:"grid",gap:7,marginTop:12}}><b style={{fontSize:12}}>Previous requests</b>{changeRequests.map(r=><div key={r.id} style={{border:"1px solid #eaecf0",borderRadius:6,padding:8}}><div style={{fontSize:12}}>{r.request_text}</div><small className="muted">{r.status==="COMPLETED"?"Handled":"Pending admin review"} · {new Date(r.created_at).toLocaleString()}</small></div>)}</div>}</div>}
{isAdmin&&selected&&<div style={{marginTop:14,paddingTop:12,borderTop:"1px solid #eaecf0"}}>{(selected.status==="APPROVED_WITH_CHANGES"||(selected.status==="PUBLISHED"&&!!String(selected.admin_notes||"").trim()))&&<div role="alert" style={{marginBottom:12,padding:"10px 12px",border:"2px solid #fdb022",borderRadius:7,background:"#fffaeb",color:"#92400e"}}><strong>⚠ MINOR CHANGES — ADMIN FOLLOW-UP REQUIRED</strong><div style={{marginTop:5,fontSize:12,whiteSpace:"pre-wrap"}}>{String(selected.admin_notes||"No concern details entered. Open listing and add review notes.").trim()}</div></div>}{["APPROVED","APPROVED_WITH_CHANGES","PUBLISHED"].includes(selected.status)?<><h3 style={{fontSize:14,margin:"0 0 8px"}}>Admin MLS Publication</h3><p className="muted" style={{fontSize:12,margin:"0 0 10px"}}>{selected.status==="PUBLISHED"?"This listing has been marked Published.":selected.status==="APPROVED_WITH_CHANGES"?"Paperwork is approved with minor corrections noted. You may publish to REALM MLS while tracking the required minor changes in Review notes.":"Paperwork is approved. The admin team must now enter this listing in REALM MLS. After REALM assigns the MLS number, record it here and mark the listing Published."}</p><label style={labelStyle}>REALM MLS number<input disabled={selected.status==="PUBLISHED"} style={fieldStyle} value={mlsNumber} onChange={e=>setMlsNumber(e.target.value)} placeholder="Enter MLS number after REALM entry"/></label><div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}>{selected.status!=="PUBLISHED"&&<button className="primary" type="button" disabled={busy||!mlsNumber.trim()} onClick={()=>adminUpdate("PUBLISHED")}>Mark Published</button>}</div></>:<><h3 style={{fontSize:14,margin:"0 0 8px"}}>Admin Paperwork Review</h3><label style={labelStyle}>Review notes<textarea rows={2} style={fieldStyle} value={adminNotes} onChange={e=>setAdminNotes(e.target.value)}/></label><div style={{display:"flex",gap:7,flexWrap:"wrap",marginTop:10}}><button className="secondary" type="button" disabled={busy} onClick={()=>adminUpdate("NEEDS_CHANGES")}>Request Changes (Hold MLS)</button><button className="secondary" type="button" disabled={busy} onClick={()=>adminUpdate("APPROVED_WITH_CHANGES")}><CheckCircle2 size={14}/> Approve with Minor Changes (Allow MLS)</button><button className="primary" type="button" disabled={busy} onClick={()=>adminUpdate("APPROVED")}><CheckCircle2 size={14}/> Approve Paperwork</button></div><p className="muted" style={{fontSize:11}}>Once approved, this panel changes to the admin MLS publication step. The admin team is responsible for entering the listing into REALM MLS and recording the assigned MLS number.</p></>}</div>}
     </div>}
    </>
   </section>}
  </div>
 </div>
}
export function AgentListingsWorkspace({user,agentId,TradePortal}){
 const [mode,setMode]=useState("LISTINGS");
 return <div><div className="tx-tabs" style={{display:"flex",gap:6,padding:"8px 12px",flexWrap:"wrap"}}><button type="button" className={mode==="LISTINGS"?"active":""} onClick={()=>setMode("LISTINGS")}>Listings</button><button type="button" className={mode==="TRADES"?"active":""} onClick={()=>setMode("TRADES")}>Trade Submissions</button></div>{mode==="LISTINGS"?<Listings user={user} agentId={agentId}/>:<TradePortal user={user} agentId={agentId}/>}</div>
}
