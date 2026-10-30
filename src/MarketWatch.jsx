import React,{useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {extractMarketWatchPdf} from "./marketWatchPdfExtractor";
import {AlertCircle,CheckCircle2,FileText,RefreshCw,Upload,ExternalLink,ShieldAlert,Eye,Trash2,RotateCcw} from "lucide-react";

const MANAGEMENT_ROLES=["SUPERADMIN","ADMIN","BROKER","BROKER_OF_RECORD","BROKER OF RECORD","BROKER-OF-RECORD","MANAGEMENT","MANAGER","OWNER"];
const money=value=>value==null||value===""?"—":new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD",maximumFractionDigits:0}).format(Number(value));
const monthLabel=value=>value?new Date(value+"T00:00:00").toLocaleDateString("en-CA",{month:"long",year:"numeric"}):"—";

export default function MarketWatch({user,role="AGENT"}){
 const management=MANAGEMENT_ROLES.includes(String(role).toUpperCase());
 const [reports,setReports]=useState([]);
 const [agentRows,setAgentRows]=useState([]);
 const [rows,setRows]=useState([]);
 const [selectedId,setSelectedId]=useState("");
 const [busy,setBusy]=useState(false);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState("");
 const [notice,setNotice]=useState("");
 const [uploadFile,setUploadFile]=useState(null);
 const [uploadMonth,setUploadMonth]=useState(new Date().toISOString().slice(0,7)+"-01");
 const [filter,setFilter]=useState("all");

 const load=useCallback(async()=>{
  if(!supabase){setLoading(false);return;}
  setLoading(true);setError("");
  try{
   const {data,error}=await supabase.from("dv_property_market_reports").select("*").order("report_period",{ascending:false});
   if(error)throw error;
   const list=data||[];
   setReports(list);
   setSelectedId(current=>list.some(x=>x.id===current)?current:(list[0]?.id||""));
  }catch(e){setError(e.message||"Unable to load Market Watch reports.");}
  finally{setLoading(false);}
 },[]);
 useEffect(()=>{load();},[load]);
 useEffect(()=>{
  if(!selectedId||!supabase){setRows([]);return;}
  let cancelled=false;
  supabase.from("dv_property_market_stat_rows").select("*").eq("market_report_id",selectedId).order("source_page").order("geography_name").then(({data,error})=>{
   if(cancelled)return;
   if(error)setError(error.message);else setRows(data||[]);
  });
  return()=>{cancelled=true;};
 },[selectedId]);
 const selected=reports.find(x=>x.id===selectedId)||null;
 const visibleReports=useMemo(()=>reports.filter(r=>filter==="all"||(filter==="review"&&(r.status!=="APPROVED"||String(r.report_period).slice(0,7)==="2026-03"))||(filter==="approved"&&r.status==="APPROVED"&&String(r.report_period).slice(0,7)!=="2026-03")),[reports,filter]);
 const openPdf=async report=>{
  if(!report?.pdf_storage_path){setError("The original PDF is not attached to this report.");return;}
  const {data,error}=await supabase.storage.from("dv-property-market-reports").createSignedUrl(report.pdf_storage_path,300);
  if(error){setError(error.message);return;}
  window.open(data.signedUrl,"_blank","noopener,noreferrer");
 };
 const returnToReview=async report=>{
  if(!management||!report)return;
  if(!window.confirm("Move "+monthLabel(report.report_period)+" back to review? This will remove it from agent access while preserving its PDF and extracted rows."))return;
  setBusy(true);setError("");setNotice("");
  try{
   const {error:reportError}=await supabase.from("dv_property_market_reports").update({status:"DRAFT",approved_by:null,approved_at:null}).eq("id",report.id);
   if(reportError)throw reportError;
   const {error:rowsError}=await supabase.from("dv_property_market_stat_rows").update({review_status:"PENDING"}).eq("market_report_id",report.id);
   if(rowsError)throw rowsError;
   setNotice("Report returned to review. Its PDF and extracted rows were preserved.");
   await load();
  }catch(e){setError("Could not return the report to review: "+(e.message||String(e)));}
  finally{setBusy(false);}
 };
 const approveReport=async report=>{
  if(!management||!report)return;
  if(!rows.length){setError("This report has no extracted detail rows. It cannot be approved.");return;}
  if(rows.some(x=>x.review_status!=="APPROVED")){setError("Review and approve every extracted row before publishing this report.");return;}
  if(!window.confirm("Publish "+monthLabel(report.report_period)+" to agent Market Watch?"))return;
  setBusy(true);setError("");setNotice("");
  try{
   const {error}=await supabase.from("dv_property_market_reports").update({status:"APPROVED",approved_by:user?.id,approved_at:new Date().toISOString()}).eq("id",report.id);
   if(error)throw error;
   setNotice("Report published to agent Market Watch.");
   await load();
  }catch(e){setError("Could not publish the report: "+(e.message||String(e)));}
  finally{setBusy(false);}
 };
 const extractSelected=async report=>{
  if(!management||!report?.pdf_storage_path)return;
  setBusy(true);setError("");setNotice("");
  try{
   const {data:blob,error:downloadError}=await supabase.storage.from("dv-property-market-reports").download(report.pdf_storage_path);
   if(downloadError)throw downloadError;
   const file=new File([blob],report.pdf_file_name||report.source_name||"market-watch.pdf",{type:"application/pdf"});
   const result=await extractMarketWatchPdf(file,report.report_period);
   if(!result.rows.length)throw new Error("The PDF was read ("+result.pages+" pages), but no rows were extracted. Diagnostic: "+(result.summary?.table_pages??0)+" table pages matched; "+(result.summary?.candidate_rows??0)+" candidate text rows found. No rows were saved.");
   const {error:rowError}=await supabase.from("dv_property_market_stat_rows").insert(result.rows.map(({report_period,...row})=>({...row,market_report_id:report.id,report_period:report.report_period})));
   if(rowError)throw rowError;
   const {error:reportError}=await supabase.from("dv_property_market_reports").update({extracted_text:result.text,metrics:{...(report.metrics||{}),extracted_pages:result.pages,extracted_rows:result.rows.length,extraction_method:"PDF_TEXT_LAYOUT",extraction_status:"PENDING_REVIEW"}}).eq("id",report.id);
   if(reportError)throw reportError;
   setNotice("Read "+result.pages+" pages and extracted "+result.rows.length+" statistical rows. All rows are pending management review.");
   await load();
  }catch(e){setError(e.message||"PDF extraction failed.");}
  finally{setBusy(false);}
 };
 const deleteReport=async report=>{
  if(!management||!report)return;
  if(!window.confirm("Permanently delete "+monthLabel(report.report_period)+", its extracted rows and its stored PDF? This cannot be undone."))return;
  setBusy(true);setError("");setNotice("");
  try{
   const {error:rowsError}=await supabase.from("dv_property_market_stat_rows").delete().eq("market_report_id",report.id);
   if(rowsError)throw rowsError;
   const {error:reportError}=await supabase.from("dv_property_market_reports").delete().eq("id",report.id);
   if(reportError)throw reportError;
   if(report.pdf_storage_path){
    const {error:storageError}=await supabase.storage.from("dv-property-market-reports").remove([report.pdf_storage_path]);
    if(storageError)throw storageError;
   }
   if(selectedId===report.id){setSelectedId("");setRows([]);}
   setNotice("Report, extracted rows and original PDF deleted.");
   await load();
  }catch(e){setError("Delete did not complete: "+(e.message||String(e)));}
  finally{setBusy(false);}
 };
 const reuploadReport=async(report,file)=>{
  if(!management||!report||!file)return;
  if(file.type!=="application/pdf"&&!file.name.toLowerCase().endsWith(".pdf")){setError("Please select a PDF file.");return;}
  if(!window.confirm("Replace the original PDF for "+monthLabel(report.report_period)+" and clear its extracted rows so the new file can be reprocessed?"))return;
  setBusy(true);setError("");setNotice("");
  const oldPath=report.pdf_storage_path;
  let newPath=null;
  try{
   newPath=(user?.id||"management")+"/"+Date.now()+"-"+file.name.replace(/[^a-zA-Z0-9._-]/g,"_");
   const {error:uploadError}=await supabase.storage.from("dv-property-market-reports").upload(newPath,file,{contentType:"application/pdf",upsert:false});
   if(uploadError)throw uploadError;
   const {error:rowsError}=await supabase.from("dv_property_market_stat_rows").delete().eq("market_report_id",report.id);
   if(rowsError)throw rowsError;
   const {error:updateError}=await supabase.from("dv_property_market_reports").update({pdf_storage_path:newPath,pdf_file_name:file.name,source_name:file.name,extracted_text:null,metrics:{},status:"DRAFT",approved_by:null,approved_at:null}).eq("id",report.id);
   if(updateError)throw updateError;
   if(oldPath){const {error:removeError}=await supabase.storage.from("dv-property-market-reports").remove([oldPath]);if(removeError)throw removeError;}
   setNotice("PDF replaced. The report is back in DRAFT with no extracted rows. Run Extract PDF to process the new file.");
   await load();
  }catch(e){
   if(newPath)await supabase.storage.from("dv-property-market-reports").remove([newPath]);
   setError("Could not replace PDF: "+(e.message||String(e)));
  }finally{setBusy(false);}
 };
 const approveAllRows=async report=>{
  if(!management||!report||!rows.length)return;
  if(!window.confirm("Approve all "+rows.length+" extracted rows for "+monthLabel(report.report_period)+"? Check the source PDF first."))return;
  setBusy(true);setError("");setNotice("");
  const {error}=await supabase.from("dv_property_market_stat_rows").update({review_status:"APPROVED"}).eq("market_report_id",report.id);
  if(error)setError(error.message);else{setRows(prev=>prev.map(x=>({...x,review_status:"APPROVED"})));setNotice("All extracted rows approved. You can now publish the report.");}
  setBusy(false);
 };
 const approveRow=async row=>{
  if(!management)return;
  setBusy(true);setError("");setNotice("");
  const {error}=await supabase.from("dv_property_market_stat_rows").update({review_status:"APPROVED"}).eq("id",row.id);
  if(error)setError(error.message);else{setRows(prev=>prev.map(x=>x.id===row.id?{...x,review_status:"APPROVED"}:x));}
  setBusy(false);
 };
 const upload=async e=>{
  e.preventDefault();
  if(!management||!uploadFile)return;
  setBusy(true);setError("");setNotice("");
  let path=null;
  try{
   path=(user?.id||"management")+"/"+Date.now()+"-"+uploadFile.name.replace(/[^a-zA-Z0-9._-]/g,"_");
   const {error:storageError}=await supabase.storage.from("dv-property-market-reports").upload(path,uploadFile,{contentType:"application/pdf",upsert:false});
   if(storageError)throw storageError;
   const {error:insertError}=await supabase.from("dv_property_market_reports").insert({
    report_period:uploadMonth,geography:"GTA",property_type:"ALL",source_name:uploadFile.name,
    metrics:{},pdf_storage_path:path,pdf_file_name:uploadFile.name,status:"DRAFT",
    created_by:user?.id||null,approved_by:null,approved_at:null
   });
   if(insertError)throw insertError;
   setNotice("Original PDF saved to the Market Watch library as a draft. It is not visible to agents and still needs extraction and review.");
   setUploadFile(null);
   await load();
  }catch(err){
   if(path)await supabase.storage.from("dv-property-market-reports").remove([path]);
   setError(err.message||"Unable to upload the Market Watch PDF.");
  }finally{setBusy(false);}
 };
 if(loading)return <section className="panel"><p>Loading Market Watch…</p></section>;
 return <div className="market-watch">
  <section className="panel" style={{background:"#0f2141",color:"#fff",padding:22,marginBottom:16}}>
   <div style={{fontSize:12,letterSpacing:2,color:"#c8b58e",fontWeight:800}}>DREAM VALLEY REALTY</div>
   <h1 style={{margin:"8px 0 4px",fontSize:26}}>Market Watch</h1>
   <p style={{margin:0,opacity:.85}}>TRREB source reports, extracted statistics and management review. Property CMA remains a separate workflow.</p>
  </section>
  {error&&<div className="notice" style={{marginBottom:12,borderColor:"#d97706"}}><AlertCircle size={17}/>{error}</div>}
  {notice&&<div className="notice" style={{marginBottom:12}}><CheckCircle2 size={17}/>{notice}</div>}
  {management&&<section className="panel" style={{marginBottom:14}}>
   <h2>Market Watch PDF Library</h2>
   <p className="muted">Upload the original monthly TRREB PDF. New uploads are saved as drafts and are never published automatically.</p>
   <form onSubmit={upload} className="formgrid">
    <label>Report month<input type="date" required value={uploadMonth} onChange={e=>setUploadMonth(e.target.value)}/></label>
    <label>Original PDF<input type="file" accept="application/pdf,.pdf" required onChange={e=>setUploadFile(e.target.files?.[0]||null)}/></label>
    <div className="actions" style={{alignItems:"end"}}><button className="primary" disabled={busy||!uploadFile}><Upload size={16}/> Save PDF as Draft</button></div>
   </form>
  </section>}
  <section className="panel">
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap"}}>
    <div><h2 style={{marginBottom:4}}>Monthly Reports</h2><p className="muted" style={{margin:0}}>{management?"Select a report to inspect its original PDF and extracted rows.":"Only approved reports available to agents are listed."}</p></div>
    <div className="actions"><select value={filter} onChange={e=>setFilter(e.target.value)} aria-label="Filter reports"><option value="all">All reports</option><option value="review">Needs review</option><option value="approved">Published</option></select><button className="secondary" onClick={load}><RefreshCw size={15}/> Refresh</button></div>
   </div>
   <div className="tablewrap" style={{marginTop:12}}>
    <table><thead><tr><th>Report month</th><th>Source PDF</th><th>Status</th><th>Rows</th><th>Action</th></tr></thead>
     <tbody>{visibleReports.map(r=><tr key={r.id} style={{background:selectedId===r.id?"#f3f6fb":undefined}}>
      <td><button type="button" className="secondary" onClick={()=>setSelectedId(r.id)}>{monthLabel(r.report_period)}</button></td>
      <td>{r.pdf_file_name||r.source_name||"No PDF attached"}</td>
      <td>{String(r.report_period).slice(0,7)==="2026-03"?"REVIEW REQUIRED":r.status||"DRAFT"}</td>
      <td>{selectedId===r.id?rows.length:"—"}</td>
      <td><div className="actions"><button className="secondary" onClick={()=>setSelectedId(r.id)}><Eye size={14}/> Review</button>{r.pdf_storage_path&&<button className="secondary" onClick={()=>openPdf(r)}><ExternalLink size={14}/> PDF</button>}{management&&<button className="secondary" disabled={busy} title="Delete report" onClick={()=>deleteReport(r)}><Trash2 size={14}/></button>}{management&&<label className="secondary" style={{display:"inline-flex",alignItems:"center",gap:5,padding:"8px 10px",borderRadius:6,cursor:"pointer"}}><RotateCcw size={14}/> Re-upload<input type="file" accept="application/pdf,.pdf" hidden disabled={busy} onChange={e=>{const file=e.target.files?.[0];if(file)reuploadReport(r,file);e.target.value="";}}/></label>}</div></td>
     </tr>)}
     {!visibleReports.length&&<tr><td colSpan="5">No reports match this filter.</td></tr>}</tbody>
    </table>
   </div>
  </section>
  {selected&&<section className="panel" style={{marginTop:14}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:12,flexWrap:"wrap"}}>
    <div><h2 style={{marginBottom:4}}>{monthLabel(selected.report_period)} — Review</h2><p className="muted" style={{margin:0}}>Source: {selected.pdf_file_name||selected.source_name||"PDF not attached"} · {rows.length} extracted rows</p></div>
    <div className="actions">{selected.pdf_storage_path&&<button className="secondary" onClick={()=>openPdf(selected)}><FileText size={15}/> Open Original PDF</button>}
     {management&&selected.pdf_storage_path&&rows.length===0&&<button className="primary" disabled={busy} onClick={()=>extractSelected(selected)}><FileText size={15}/> Extract PDF</button>}
     {management&&rows.length>0&&rows.some(x=>x.review_status!=="APPROVED")&&<button className="secondary" disabled={busy} onClick={()=>approveAllRows(selected)}>Approve All Rows</button>}
     {management&&selected.status==="APPROVED"&&<button className="secondary" disabled={busy} onClick={()=>returnToReview(selected)}><ShieldAlert size={15}/> Move to Review</button>}
     {management&&selected.status!=="APPROVED"&&<button className="primary" disabled={busy||!rows.length||rows.some(x=>x.review_status!=="APPROVED")} onClick={()=>approveReport(selected)}>Approve & Publish</button>}
    </div>
   </div>
   {management&&rows.length>0&&<p className="muted" style={{marginTop:12}}>Check the original PDF page against each extracted row. Use Approve on a row only after confirming its geography, property type and figures.</p>}
   <div className="tablewrap" style={{marginTop:12,maxHeight:560,overflow:"auto"}}>
    <table><thead><tr><th>Page</th><th>Geography</th><th>Level</th><th>Property type</th><th>Sales</th><th>Avg. price</th><th>Median</th><th>New listings</th><th>DOM</th><th>Review</th></tr></thead>
     <tbody>{rows.map(row=><tr key={row.id}><td>{row.source_page||"—"}</td><td>{row.geography_name}</td><td>{row.geography_level}</td><td>{row.property_type}</td><td>{row.metric_values?.sales??"—"}</td><td>{money(row.metric_values?.average_price)}</td><td>{money(row.metric_values?.median_price)}</td><td>{row.metric_values?.new_listings??"—"}</td><td>{row.metric_values?.days_on_market??"—"}</td><td>{row.review_status==="APPROVED"?<span style={{color:"#167447"}}>Approved</span>:management?<button className="secondary" disabled={busy} onClick={()=>approveRow(row)}>Approve row</button>:"Pending"}</td></tr>)}
     {!rows.length&&<tr><td colSpan="10">No extracted detail rows are attached. Click “Extract PDF” to read the original report and create pending rows for review.</td></tr>}</tbody>
    </table>
   </div>
   {String(selected.report_period).slice(0,7)==="2026-03"&&<div className="notice" style={{marginTop:12,borderColor:"#d97706"}}><ShieldAlert size={17}/> March 2026 is excluded from agent access while its 319 extracted rows are being rechecked. The source PDF and rows remain intact.</div>}
  </section>}
 </div>;
}
