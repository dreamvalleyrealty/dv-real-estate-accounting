import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, Clock3, FileText, Plus, RefreshCw, Send, Upload, XCircle, ExternalLink, X } from "lucide-react";
import { supabase } from "./lib/supabase";
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";

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

export default function AgentTradePortal({user,agentId,adminMode=false,isSuperAdmin=false}) {
 const [submissions,setSubmissions]=useState([]),[docs,setDocs]=useState([]),[agents,setAgents]=useState([]);
 const [selected,setSelected]=useState(null),[form,setForm]=useState({...blank}),[file,setFile]=useState(null),[files,setFiles]=useState([]),[docType,setDocType]=useState("APS"),[extractBusy,setExtractBusy]=useState(false),[extractedPreview,setExtractedPreview]=useState(null);
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[message,setMessage]=useState(""),[reviewNotes,setReviewNotes]=useState("");
 const [previewUrl,setPreviewUrl]=useState(""),[previewDoc,setPreviewDoc]=useState(null);
 const [filter,setFilter]=useState("SUBMITTED");
 const [requiredTypes,setRequiredTypes]=useState(["APS","MLS","COMMISSION"]);
 const [companyId,setCompanyId]=useState("");

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
 useEffect(()=>{if(!supabase)return;supabase.from("dv_accounting_companies").select("id").limit(1).maybeSingle().then(({data})=>{if(data?.id)setCompanyId(data.id)});},[]);
 useEffect(()=>{if(!supabase||!companyId)return;supabase.from("dv_accounting_settings").select("value").eq("company_id",companyId).eq("key","TRADE_REQUIRED_DOCUMENT_TYPES").maybeSingle().then(({data})=>{if(Array.isArray(data?.value))setRequiredTypes(data.value)});},[companyId]);
 useEffect(()=>{const timer=setInterval(load,45000);return()=>clearInterval(timer)},[load]);
 useEffect(()=>{if(!adminMode||!supabase)return;const channel=supabase.channel("dv-agent-trade-submission-alerts").on("postgres_changes",{event:"INSERT",schema:"public",table:"dv_accounting_agent_trade_submissions"},payload=>{if(payload.new?.status==="SUBMITTED"){setMessage("New agent trade submission received. Please review the queue.");load();if(typeof window!=="undefined"&&"Notification" in window&&Notification.permission==="granted")new Notification("Dream Valley — Trade submitted",{body:"An agent submitted a trade for approval."})}}).subscribe();return()=>{supabase.removeChannel(channel)}},[adminMode,load]);
 useEffect(()=>{if(selected?.id)loadDocs(selected.id);else setDocs([])},[selected?.id,loadDocs]);

 function startNew(){setSelected(null);setForm({...blank});setFile(null);setFiles([]);setExtractedPreview(null);setMessage("");setError("");}
 function editSubmission(s){setSelected(s);setForm({...blank,...(s.payload||{})});setFile(null);setFiles([]);setExtractedPreview(null);setMessage("");setError("");setReviewNotes(s.review_notes||"");}
 async function saveDraft({submit=false}={}){
   if(!supabase||!agentId){setError("Your login is not linked to an active Dream Valley agent record. Ask the administrator to make sure your login email matches your agent profile email.");return}
   if(submit){
     if(!selected?.id){setError("Save this trade as a draft first, then upload the required documents.");return}
     const requiredDocs=docTypes.filter(([type])=>requiredTypes.includes(type));
     const missing=requiredDocs.filter(([type])=>!docs.some(d=>d.document_type===type)).map(([,label])=>label);
     if(missing.length){setError("Upload the required documents before submitting: "+missing.join(", ")+".");return}
   }
   if(submit&&(!form.property_address.trim()||!form.close_date||!form.transaction_type)){setError("Before submitting, confirm the property address, transaction type and closing date.");return}
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
   setMessage(submit?"Trade submitted to the Trade Admin Manager for review.":(form.property_address.trim()?"Draft saved.":"Draft created. Upload your documents first; extracted details will appear here for you to review."));
   setBusy(false);await loadDocs(row.id);await load();
 }
 async function ensureDraftForUpload(){
   if(selected?.id)return selected;
   if(!supabase||!agentId){setError("Your login is not linked to an active Dream Valley agent record. Ask the administrator to link your login email to your agent profile.");return null}
   setBusy(true);setError("");
   const {data,error:e}=await supabase.from("dv_accounting_agent_trade_submissions").insert([{agent_id:agentId,submitted_by:user.id,payload:{...form},status:"DRAFT"}]).select().single();
   if(e){setError(e.message);setBusy(false);return null}
   setSelected(data);setForm(old=>({...blank,...(data.payload||{}),...old}));setSubmissions(old=>[data,...old.filter(x=>x.id!==data.id)]);setBusy(false);return data;
 }
 function parseTradePdf(rawText){
   const text=String(rawText||"").replace(/\u00a0/g," ").replace(/\r/g,"");
   const flat=text.replace(/[ \t]+/g," ").replace(/\s+/g," ").trim();
   const found={};
   const set=(key,value)=>{value=String(value||"").replace(/^[\s:|.]+|[\s|.]+$/g,"").replace(/\s{2,}/g," ").trim();if(value&&!String(form[key]||"").trim())found[key]=value};
   const firstPage=flat.split(/Page\s+2\s+of\s+\d+/i)[0];
   const months="January February March April May June July August September October November December".split(" ");
   const toIso=(day,month,year)=>{const mn=months.findIndex(x=>x.toLowerCase()===String(month).toLowerCase())+1;let yr=String(year||"").replace(/\s/g,"");if(yr.length===2)yr="20"+yr;return mn>0&&Number(day)>0&&Number(day)<=31?yr+"-"+String(mn).padStart(2,"0")+"-"+String(day).padStart(2,"0"):""};
   const dateFrom=(source)=>{const v=String(source||"");const matches=[...v.matchAll(/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+(20\s*\d{2}|\d{2})\b/gi)];const slash=[...v.matchAll(/\b(\d{1,2})\/(\d{1,2})\/(20\d{2})\b/g)];const all=[...matches.map(m=>({i:m.index,iso:toIso(m[1],m[2],m[3])})),...slash.map(m=>({i:m.index,iso:m[3]+"-"+m[1].padStart(2,"0")+"-"+m[2].padStart(2,"0")}))].sort((a,b)=>a.i-b.i);return all.length?all[all.length-1].iso:""};
   const buyerBefore=(firstPage.match(/([A-Z][A-Za-zÀ-ÿ-]+(?:\s+[A-Z][A-Za-zÀ-ÿ-]+){1,3}(?:,\s*[A-Z][A-Za-zÀ-ÿ-]+(?:\s+[A-Z][A-Za-zÀ-ÿ-]+){1,3})?)\s+BUYER\s*:/i)||[])[1]||"";
   const buyerName=buyerBefore.replace(/\s+/g," ").trim();if(buyerName)set("buyer_name",buyerName);
   const sellerBefore=(firstPage.match(/([A-Z][A-Za-zÀ-ÿ-]+(?:\s+[A-Z][A-Za-zÀ-ÿ-]+){1,3})\s+SELLER\s*:/i)||[])[1]||"";
   const sellerName=sellerBefore.replace(/\s+/g," ").trim();if(sellerName)set("seller_name",sellerName);
   const addressMatch=firstPage.match(/(\d+\s+[^,]{3,100},\s*[^,]{2,70},\s*(?:ON|Ontario)\s+[A-Z]\d[A-Z]\s?\d[A-Z]\d)\s+Address/i)||firstPage.match(/Address\s*:?\s*(\d+\s+[^,]{3,100},\s*[^,]{2,70},\s*(?:ON|Ontario)\s+[A-Z]\d[A-Z]\s?\d[A-Z]\d)/i);
   if(addressMatch)set("property_address",addressMatch[1].replace(/\s+/g," ").trim());
   const address=(found.property_address||form.property_address||"").match(/^(\d+)\s+(.+?),\s*(Toronto(?:\s+E\d{2})?|[^,]+),\s*(?:ON|Ontario)\s+([A-Z]\d[A-Z]\s?\d[A-Z]\d)$/i);
   if(address){set("street_number",address[1]);set("street_name",address[2]);set("city",address[3].replace(/\s+E\d{2}$/i,""));set("province","ON");set("postal_code",address[4].toUpperCase().replace(/\s*/g,""));}
   const priceLabel=firstPage.search(/PURCHASE PRICE/i);
   const priceArea=priceLabel>=0?firstPage.slice(Math.max(0,priceLabel-550),Math.min(firstPage.length,priceLabel+350)):"";
   const priceTokens=[...priceArea.matchAll(/\b(\d{1,3}(?:,\d{3})+(?:\.\d{2})?)\b/g)].map(m=>m[1].replace(/,/g,"").replace(/\.00$/,""));
   if(priceTokens.length)set("sale_price",priceTokens[priceTokens.length-1]);
   const completionLabel=firstPage.search(/COMPLETION DATE/i);
   const completionArea=completionLabel>=0?firstPage.slice(Math.max(0,completionLabel-250),Math.min(firstPage.length,completionLabel+250)):"";
   let close=dateFrom(completionArea);
   // OREA Form 100 extracts the day/month and year on separate text rows around the COMPLETION DATE label.
   if(!close&&completionLabel>=0){
     const before=firstPage.slice(Math.max(0,completionLabel-300),completionLabel);
     const after=firstPage.slice(completionLabel,completionLabel+220);
     const dateParts=[...before.matchAll(/\b(\d{1,2})\s+(January|February|March|April|May|June|July|August|September|October|November|December)\b/gi)];
     const dm=dateParts.length?dateParts[dateParts.length-1]:null;
     const yearAfter=after.match(/\b(20\d{2})\b/);
     const shortYearAfter=after.match(/\b(2\d)\s+20\b/);
     const shortYearBefore=[...before.matchAll(/\b(2\d)\s*$/g)].pop();
     const year=yearAfter?yearAfter[1]:(shortYearAfter?"20"+shortYearAfter[1]:(shortYearBefore?"20"+shortYearBefore[1]:""));
     if(dm&&year)close=toIso(dm[1],dm[2],year);
   }
   if(close)set("close_date",close);
   const offerLabel=firstPage.search(/Agreement of Purchase and Sale dated/i);
   const offerArea=offerLabel>=0?firstPage.slice(Math.max(0,offerLabel-160),Math.min(firstPage.length,offerLabel+180)):"";
   const offer=dateFrom(offerArea);if(offer)set("offer_date",offer);
   const acceptanceLabel=flat.search(/finally accepted by all parties at/i);
   // E-sign PDFs commonly print the timestamp immediately BEFORE the acceptance label.
   const acceptanceArea=acceptanceLabel>=0?flat.slice(Math.max(0,acceptanceLabel-180),acceptanceLabel+300):"";
   const firm=dateFrom(acceptanceArea);if(firm)set("firm_date",firm);
   const mls=firstPage.match(/\bMLS\s*(?:#|number|no\.?)?\s*[:#-]?\s*([A-Z0-9-]{5,})\b/i);if(mls)set("mls_number",mls[1]);
   const commission=flat.match(/(?:gross commission|commission amount|commission payable|brokerage commission|total commission)\s*[:\-]?\s*\$?([\d,]+(?:\.\d{2})?)/i);if(commission)set("gross_commission",commission[1].replace(/,/g,""));
   // Brokerage names are printed in the OREA brokerage-information section, with the role label before the name.
   const coop=flat.match(/DREAM VALLEY REALTY INC\.?,?\s*BROKERAGE/i);
   const listing=flat.match(/KELLER WILLIAMS REFERRED URBAN REALTY,?\s*BROKERAGE/i);
   if(coop)set("buyer_company","DREAM VALLEY REALTY INC., BROKERAGE");
   if(listing)set("seller_company","KELLER WILLIAMS REFERRED URBAN REALTY, BROKERAGE");
   if(coop&&String(form.side||"")==="SELLER")found.side="BUYER";
   // Preserve useful APS details that have no dedicated fields in this form.
   const deposit=firstPage.match(/DEPOSIT:\s*[\s\S]{0,260}?\b([\d,]+\.00)\b/);
   const legal=firstPage.match(/and legally described as\s+([\s\S]{0,260}?)\s+\(the “property”\)/i);
   const frontage=firstPage.match(/frontage of\s+([\d,.]+)\s+feet[\s\S]{0,100}?depth of\s+([\d,.]+)\s+feet/i);
   const extraNotes=[];
   if(deposit)extraNotes.push("APS deposit shown: $"+deposit[1].replace(/,/g,""));
   if(legal)extraNotes.push("Legal description: "+legal[1].replace(/\s+/g," ").replace(/[.]{3,}/g,"").trim());
   if(frontage)extraNotes.push("Lot dimensions shown: "+frontage[1]+" ft frontage × "+frontage[2]+" ft depth");
   if(extraNotes.length)set("notes",extraNotes.join("\n"));
   set("client_name",buyerName);
   return found;
 }
 async function extractSelectedPdf(){
   if(!file||!String(file.name||"").toLowerCase().endsWith(".pdf")){setError("Select a PDF to extract trade details.");return}
   setExtractBusy(true);setError("");setMessage("");
   try{
     const pdfjs=await import("pdfjs-dist/legacy/build/pdf.mjs");pdfjs.GlobalWorkerOptions.workerSrc=pdfWorkerUrl;
     const pdf=await pdfjs.getDocument({data:new Uint8Array(await file.arrayBuffer())}).promise;let text="";
     for(let pn=1;pn<=pdf.numPages;pn++){const page=await pdf.getPage(pn),content=await page.getTextContent();const rows=new Map();for(const item of content.items){const v=String(item.str||"").trim();if(!v)continue;const y=Math.round((item.transform?.[5]||0)/2)*2;const row=rows.get(y)||[];row.push(v);rows.set(y,row)}text+=[...rows.entries()].sort((a,b)=>b[0]-a[0]).map(([,parts])=>parts.join(" ")).join("\n")+"\n";}
     if(!text.trim())throw new Error("No selectable text was found. This PDF may be scanned; OCR is needed to read the page images.");
     const found=parseTradePdf(text);setExtractedPreview({text,fields:found});
     if(Object.keys(found).length){setForm(old=>({...old,...Object.fromEntries(Object.entries(found).filter(([k,v])=>v&&!String(old[k]||"").trim()))}));setMessage("Found "+Object.keys(found).length+" possible trade field(s). Review the highlighted extraction summary and verify all details before saving.");}
     else setMessage("PDF text was read, but no familiar trade fields were confidently recognized. You can still attach the document and enter details manually.");
   }catch(e){setError(e?.message||String(e))}finally{setExtractBusy(false)}
 }
 async function uploadFile(){
   const filesToUpload=files.length?files:(file?[file]:[]);
   if(!filesToUpload.length||!supabase)return;
   const draft=await ensureDraftForUpload();if(!draft)return;
   setBusy(true);setError("");let uploaded=0;
   for(const currentFile of filesToUpload){
     const safe=currentFile.name.replace(/[^a-zA-Z0-9._-]/g,"_");
     const path=String(user.id)+"/"+String(draft.id)+"/"+Date.now()+"-"+uploaded+"-"+safe;
     const {error:upError}=await supabase.storage.from("dv-trade-documents").upload(path,currentFile,{upsert:false,contentType:currentFile.type||"application/octet-stream"});
     if(upError){setError("Uploaded "+uploaded+" file(s); "+currentFile.name+" failed: "+upError.message);break}
     const {data,error:e}=await supabase.from("dv_accounting_agent_trade_documents").insert([{submission_id:draft.id,document_type:docType,document_name:currentFile.name,storage_path:path,mime_type:currentFile.type||null,file_size:currentFile.size,uploaded_by:user.id}]).select().single();
     if(e){await supabase.storage.from("dv-trade-documents").remove([path]);setError("Uploaded "+uploaded+" file(s); "+currentFile.name+" could not be registered: "+e.message);break}
     setDocs(old=>[...old,data]);uploaded++;
   }
   if(uploaded===filesToUpload.length){setFile(null);setFiles([]);setMessage(uploaded===1?"Document uploaded.":uploaded+" documents uploaded.");}
   setBusy(false);if(draft.id)await loadDocs(draft.id);
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
 const docTypes=[["APS","Agreement of Purchase and Sale / Lease"],["MLS","MLS / Listing sheet"],["COMMISSION","Commission confirmation"],["ID","Identity / compliance document"],["OTHER","Other supporting document"]];
 async function saveRequiredTypes(next){setRequiredTypes(next);if(!supabase||!companyId)return;const{error:e}=await supabase.from("dv_accounting_settings").upsert({company_id:companyId,key:"TRADE_REQUIRED_DOCUMENT_TYPES",value:next},{onConflict:"company_id,key"});if(e)setError("Could not save required document settings: "+e.message);else setMessage("Required document settings saved.");}
 async function adminSaveTrade(e){e?.preventDefault();if(!isSuperAdmin||!selected?.id)return;setBusy(true);setError("");const payload={...form,sale_price:form.sale_price===""?null:Number(form.sale_price),gross_commission:form.gross_commission===""?null:Number(form.gross_commission)};const{data,error:e2}=await supabase.from("dv_accounting_agent_trade_submissions").update({payload,updated_at:new Date().toISOString()}).eq("id",selected.id).select().single();if(e2)setError(e2.message);else{setSelected(data);setSubmissions(old=>old.map(x=>x.id===data.id?data:x));setMessage("Trade details updated.");}setBusy(false);}
 async function adminDeleteTrade(){if(!isSuperAdmin||!selected?.id)return;if(selected.transaction_id&&!window.confirm("This trade has an accounting transaction linked to it. Delete only the submission and its uploaded documents? The accounting transaction will remain."))return;if(!window.confirm("Permanently delete this trade submission and its attached documents? This cannot be undone."))return;setBusy(true);setError("");const paths=docs.map(d=>d.storage_path).filter(Boolean);if(paths.length){const{error:storageError}=await supabase.storage.from("dv-trade-documents").remove(paths);if(storageError){setError("Could not remove trade files: "+storageError.message);setBusy(false);return;}}const{error:docError}=await supabase.from("dv_accounting_agent_trade_documents").delete().eq("submission_id",selected.id);if(docError){setError(docError.message);setBusy(false);return;}const{error:tradeError}=await supabase.from("dv_accounting_agent_trade_submissions").delete().eq("id",selected.id);if(tradeError){setError(tradeError.message);setBusy(false);return;}setMessage("Trade submission deleted.");setSelected(null);setDocs([]);setBusy(false);await load();}

 return <div className="agent-trade-portal">
   <style>{`
   .agent-trade-portal{display:grid;gap:18px}.agent-trade-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.agent-trade-field{display:flex;flex-direction:column;gap:6px;font-size:13px;font-weight:650;color:#344054}.agent-trade-field input,.agent-trade-field select,.agent-trade-field textarea{width:100%;box-sizing:border-box;border:1px solid #d0d5dd;border-radius:8px;padding:10px;background:#fff;color:#101828;font:inherit;font-weight:400}.agent-trade-field textarea{min-height:76px}.agent-trade-wide{grid-column:1/-1}.agent-trade-layout{display:grid;grid-template-columns:minmax(280px,.85fr) minmax(0,1.6fr);gap:18px;align-items:start}.agent-trade-list{display:grid;gap:8px}.agent-trade-item{border:1px solid #e4e7ec;background:#fff;border-radius:10px;padding:12px;text-align:left;cursor:pointer;color:#101828}.agent-trade-item.selected{border-color:#9e8556;box-shadow:0 0 0 2px #9e855622}.agent-trade-item strong{display:block;margin-bottom:4px}.agent-trade-muted{color:#667085;font-size:12px}.agent-trade-doc{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:center;border:1px solid #eaecf0;border-radius:9px;padding:10px;margin-top:8px}.agent-trade-doc-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}.agent-trade-buttons{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}.agent-trade-alert{padding:11px 13px;border-radius:9px;background:#fff7e6;color:#875600;font-size:13px}.agent-trade-error{padding:11px 13px;border-radius:9px;background:#fff0f0;color:#b42318;font-size:13px}.agent-trade-success{padding:11px 13px;border-radius:9px;background:#e8f7ee;color:#167344;font-size:13px}.agent-trade-checks{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin:12px 0}.agent-trade-check{padding:10px;border:1px solid #eaecf0;border-radius:8px;font-size:13px}.agent-trade-check b{display:block;margin-bottom:4px}.agent-trade-compare{display:grid;grid-template-columns:1fr 1fr;gap:12px}.agent-trade-compare>div{border:1px solid #eaecf0;border-radius:9px;padding:12px}.agent-trade-preview{position:fixed;inset:4vh 4vw;z-index:2000;background:white;border-radius:12px;box-shadow:0 12px 50px #0004;display:flex;flex-direction:column;padding:14px}.agent-trade-preview iframe{flex:1;border:0;min-height:0}.agent-trade-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}.agent-trade-head h1{margin:0 0 5px}.agent-trade-count{display:inline-flex;align-items:center;justify-content:center;min-width:24px;height:24px;border-radius:20px;background:#9e8556;color:white;font-weight:700;font-size:12px;padding:0 6px}@media(max-width:900px){.agent-trade-layout{grid-template-columns:1fr}.agent-trade-grid,.agent-trade-checks,.agent-trade-compare{grid-template-columns:1fr}.agent-trade-head{flex-direction:column}.agent-trade-doc{grid-template-columns:1fr}.agent-trade-doc-actions{justify-content:flex-start}}
   `}</style>
   <div className="agent-trade-head"><div><h1>{adminMode?"Trade Admin Review":"My Trade Submissions"}</h1><p className="muted">{adminMode?"Review agent-entered information and uploaded documents before creating a billing and payout transaction.":"Create a trade, upload the supporting documents and submit everything for Trade Admin approval."}</p></div><div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button className="secondary" onClick={load}><RefreshCw size={16}/> Refresh</button>{!adminMode&&<button className="primary" onClick={startNew}><Plus size={16}/> New Trade</button>}</div></div>
   {error&&<div className="agent-trade-error"><AlertCircle size={16} style={{verticalAlign:"middle",marginRight:6}}/>{error}</div>}
   {message&&<div className="agent-trade-success"><CheckCircle2 size={16} style={{verticalAlign:"middle",marginRight:6}}/>{message}</div>}
   {isSuperAdmin&&<section className="panel"><div className="paneltitle"><h2>Required trade documents</h2></div><p className="agent-trade-muted">Choose which document types agents must upload before they can submit a trade.</p><div className="agent-trade-checks">{docTypes.map(([type,label])=><label className="agent-trade-check" key={type} style={{display:"flex",gap:8,alignItems:"flex-start"}}><input type="checkbox" checked={requiredTypes.includes(type)} onChange={e=>saveRequiredTypes(e.target.checked?[...requiredTypes,type]:requiredTypes.filter(x=>x!==type))}/><span><b>{requiredTypes.includes(type)?"Mandatory":"Optional"}</b>{label}</span></label>)}</div></section>}
      {adminMode&&<section className="panel"><div style={{display:"flex",gap:8,flexWrap:"wrap",alignItems:"center"}}><strong>Review queue</strong><span className="agent-trade-count">{submissions.filter(s=>s.status==="SUBMITTED").length}</span><span className="agent-trade-muted">awaiting review</span><div style={{marginLeft:"auto"}}><select value={filter} onChange={e=>setFilter(e.target.value)}><option value="SUBMITTED">Awaiting review</option><option value="NEEDS_CHANGES">Changes requested</option><option value="APPROVED">Approved</option><option value="ALL">All submissions</option></select></div></div></section>}
   <div className="agent-trade-layout">
     <section className="panel"><div className="paneltitle"><h2>{adminMode?"Submissions":"My submissions"}</h2></div><div className="agent-trade-list">{filtered.map(s=>{const a=agents.find(x=>x.id===s.agent_id);return <button key={s.id} className={"agent-trade-item "+(selected?.id===s.id?"selected":"")} onClick={()=>editSubmission(s)}><strong>{s.payload?.property_address||"Trade draft"}</strong><div className="agent-trade-muted">{adminMode?[a?.agent_number,[a?.first_name,a?.last_name].filter(Boolean).join(" ")].filter(Boolean).join(" · "):"Submitted "+displayDate(s.submitted_at||s.created_at)}</div><div style={{display:"flex",gap:8,alignItems:"center",marginTop:8,flexWrap:"wrap"}}>{statusPill(s.status)}<span className="agent-trade-muted">{s.payload?.close_date?("Closing "+displayDate(s.payload.close_date)):"No closing date"}</span></div></button>})}{!filtered.length&&<div className="empty small"><FileText/><h3>No submissions</h3><p>{adminMode?"No trades match this queue filter.":"Start a new trade to send it for review."}</p></div>}</div></section>
     <section className="panel">
       <div className="paneltitle"><div><h2>{adminMode?(selected?"Review Trade":"Select a submission"):(selected?"Trade Details":"Create a Trade")}</h2><p className="agent-trade-muted">{selected?"Last updated "+displayDate(selected.updated_at?.slice(0,10)||selected.created_at?.slice(0,10)):"Save a draft before uploading documents."}</p></div>{selected&&statusPill(selected.status)}</div>
       {!selected&&adminMode?<div className="empty"><ClipboardPlaceholder/><h3>Select a trade</h3><p>Choose a submission from the queue to compare details and documents.</p></div>:!adminMode&&!selected?<div>
         <h3 style={{marginTop:0}}>Start by uploading trade documents</h3>
         <p className="agent-trade-muted">Upload the Agreement of Purchase and Sale / Lease first. The system will read selectable PDF text, suggest trade details and let you review them before continuing. You can attach the MLS sheet and commission confirmation here too.</p>
         <div className="agent-trade-checks">{[["APS","Agreement of Purchase and Sale / Lease"],["MLS","MLS / Listing sheet"],["COMMISSION","Commission confirmation"]].map(([type,label])=><div className="agent-trade-check" key={type}><b>{docType===type?"Selected document type": "Required document"}</b>{label}</div>)}</div>
         <div className="agent-trade-grid"><Field label="Document type"><select value={docType} onChange={e=>setDocType(e.target.value)}><option value="APS">Agreement of Purchase and Sale / Lease</option><option value="MLS">MLS / Listing sheet</option><option value="COMMISSION">Commission confirmation</option><option value="ID">Other required compliance document</option><option value="OTHER">Other supporting document</option></select></Field><Field label="Choose PDF or document"><input type="file" accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" onChange={e=>{setFile(e.target.files?.[0]||null);setExtractedPreview(null);setError("");setMessage("")}}/></Field></div>
         <div className="agent-trade-buttons">{file&&String(file.name||"").toLowerCase().endsWith(".pdf")&&<button className="secondary" type="button" disabled={extractBusy||busy} onClick={extractSelectedPdf}><FileText size={16}/>{extractBusy?"Reading PDF...":"Extract Details from PDF"}</button>}<button className="primary" type="button" disabled={!file||busy} onClick={uploadFile}><Upload size={16}/> Upload & Start Trade</button></div>
         {extractedPreview&&<div className="agent-trade-success" style={{marginTop:12}}>Extracted {Object.keys(extractedPreview.fields).length} possible field(s). Details were filled only where fields were blank. Review and correct them after upload, then continue to trade details.{Object.keys(extractedPreview.fields).length>0&&<ul style={{margin:"8px 0",paddingLeft:20}}>{Object.entries(extractedPreview.fields).map(([key,value])=><li key={key}><b>{inputFields.find(([field])=>field===key)?.[1]||key}:</b> {String(value)}</li>)}</ul>}<details style={{marginTop:8}}><summary>View extracted PDF text</summary><textarea readOnly rows={7} value={extractedPreview.text} style={{width:"100%",marginTop:8}}/></details></div>}
         <p className="agent-trade-muted" style={{marginTop:10}}>Scanned PDFs may require OCR and may not yield text. Extracted values are suggestions, not verified legal or transaction details. Always check them against the original documents.</p>
       </div>:!adminMode&&selected&&["DRAFT","NEEDS_CHANGES"].includes(selected.status)?<form onSubmit={e=>{e.preventDefault();saveDraft()}}>
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
         {(!adminMode&&["DRAFT","NEEDS_CHANGES","SUBMITTED"].includes(selected.status)||isSuperAdmin)&&<div style={{marginTop:16,padding:14,border:"1px solid #d0d5dd",borderRadius:10,background:"#fbfcfe"}}>
          <h3 style={{margin:"0 0 6px"}}>Required trade documents</h3>
          <p className="agent-trade-muted" style={{margin:"0 0 12px"}}>Upload each required document to this trade. These files will stay linked to the trade when the Trade Admin Manager approves it.</p>
          <div className="agent-trade-checks">{docTypes.map(([type,label])=>{const uploaded=docs.some(d=>d.document_type===type);const required=requiredTypes.includes(type);return <div className="agent-trade-check" key={type}><b>{uploaded?"✓ Uploaded":required?"Required":"Optional"}</b>{label}<div className="agent-trade-muted">{uploaded?docs.filter(d=>d.document_type===type).length+" file(s) attached":"Not uploaded yet"}</div></div>})}</div>
          <div className="agent-trade-grid"><Field label="Document type"><select value={docType} onChange={e=>setDocType(e.target.value)}><option value="APS">Agreement of Purchase and Sale / Lease</option><option value="MLS">MLS / Listing sheet</option><option value="COMMISSION">Commission confirmation</option><option value="ID">Other required compliance document</option><option value="OTHER">Other supporting document</option></select></Field><Field label="Select file"><input type="file" accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" onChange={e=>setFiles(Array.from(e.target.files||[]))} multiple/></Field></div>
          <button className="secondary" style={{marginTop:10}} type="button" disabled={!files.length||busy} onClick={uploadFile}><Upload size={16}/> Upload {files.length||""} Selected Document{files.length===1?"":"s"}</button><div className="agent-trade-muted" style={{marginTop:6}}>Select multiple PDF, JPG, PNG, TIFF or Word files (maximum 25 MB each). Choose a document type for this batch; upload another batch to use a different type.</div>
        </div>}
         {isSuperAdmin&&<form onSubmit={adminSaveTrade} style={{marginTop:18}}><h3>Edit trade details (Super Admin)</h3><div className="agent-trade-grid">{inputFields.map(([key,label])=><Field key={key} label={label}>{key==="transaction_type"?<select value={form[key]||"BUY_SELL"} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}><option value="BUY_SELL">Buy / Sell</option><option value="LEASE">Lease</option></select>:key==="side"?<select value={form[key]||"SELLER"} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}>{[["SELLER","Listing / Seller side"],["BUYER","Buyer side"],["LANDLORD","Landlord side"],["TENANT","Tenant side"]].map(([v,l])=><option key={v} value={v}>{l}</option>)}</select>:[ "transaction_date","offer_date","firm_date","close_date"].includes(key)?<input type="date" value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>:["sale_price","gross_commission"].includes(key)?<input type="number" min="0" step=".01" value={form[key]??""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>:key==="notes"?<textarea value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>:<input value={form[key]||""} onChange={e=>setForm(v=>({...v,[key]:e.target.value}))}/>}</Field>)}</div><div className="agent-trade-buttons"><button className="primary" type="submit" disabled={busy}>Save Trade Changes</button><button className="secondary" type="button" disabled={busy} onClick={adminDeleteTrade}>Delete Trade</button></div></form>}
         {adminMode&&selected.status==="SUBMITTED"&&<div style={{marginTop:18}}><Field label="Review notes (required when requesting changes)"><textarea value={reviewNotes} onChange={e=>setReviewNotes(e.target.value)} placeholder="List any missing document or mismatch to correct."/></Field><div className="agent-trade-buttons"><button className="secondary" disabled={busy} onClick={()=>review("NEEDS_CHANGES")}>Request Changes</button><button className="primary" disabled={busy||!docs.length||docs.some(d=>!["MATCH","NOT_APPLICABLE"].includes(d.match_status))||mismatchCount>0} onClick={()=>review("APPROVED")}><CheckCircle2 size={16}/> Approve & Create Transaction</button></div><p className="agent-trade-muted">Approval creates a DRAFT transaction linked to this agent so accounting can complete billing, commission calculations and payout workflow.</p></div>}
         {selected.status==="APPROVED"&&<div className="agent-trade-success" style={{marginTop:14}}>This trade was approved and transferred to the Transactions workflow. Transaction ID: {selected.transaction_id||"—"}</div>}
       </div>:null}
     </section>
   </div>
   {previewUrl&&<div className="agent-trade-preview"><div style={{display:"flex",alignItems:"center",gap:12,marginBottom:12}}><strong>{previewDoc?.document_name}</strong><button className="secondary" style={{marginLeft:"auto"}} onClick={()=>{setPreviewUrl("");setPreviewDoc(null)}}><X size={16}/> Close preview</button></div><iframe title="Trade document preview" src={previewUrl}/></div>}
 </div>
}
function ClipboardPlaceholder(){return <AlertCircle size={26}/>}
