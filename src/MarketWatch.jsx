import React,{useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {AlertCircle,CheckCircle2,FileText,RefreshCw,Upload,ExternalLink,ShieldAlert,Eye} from "lucide-react";

const MANAGEMENT_ROLES=["SUPERADMIN","ADMIN","BROKER","MANAGEMENT","MANAGER"];
const money=value=>value==null||value===""?"—":new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD",maximumFractionDigits:0}).format(Number(value));
const monthLabel=value=>value?new Date(value+"T00:00:00").toLocaleDateString("en-CA",{month:"long",year:"numeric"}):"—";

export default function MarketWatch({user,role="AGENT"}){
 const management=MANAGEMENT_ROLES.includes(String(role).toUpperCase());
 const [reports,setReports]=useState([]);\n const [agentRows,setAgentRows]=useState([]);
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
 if(!management)return <div className="market-watch">
  <section className="panel" style={{background:"#0f2141",color:"#fff",padding:22,marginBottom:16}}>
   <div style={{fontSize:12,letterSpacing:2,color:"#c8b58e",fontWeight:800}}>DREAM VALLEY REALTY</div>
   <h1 style={{margin:"8px 0 4px",fontSize:26}}>Market Watch</h1>
   <p style={{margin:0,opacity:.85}}>Approved TRREB Market Watch statistics. Original reports and unverified figures are held for management review.</p>
  </section>
  {error&&<div className="notice" style={{marginBottom:12,borderColor:"#d97706"}}><AlertCircle size={17}/>{error}</div>}
  <section className="panel">
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap"}}><div><h2 style={{marginBottom:4}}>Published Market Statistics</h2><p className="muted" style={{margin:0}}>Showing approved source rows only. No averages or totals are recalculated here.</p></div><button className="secondary" onClick={load}><RefreshCw size={15}/> Refresh</button></div>
   <div className="tablewrap" style={{marginTop:12}}><table><thead><tr><th>Month</th><th>Geography</th><th>Level</th><th>Property type</th><th>Sales</th><th>Average price</th><th>Median price</th><th>New listings</th><th>DOM</th></tr></thead><tbody>
    {agentRows.map(row=><tr key={row.id}><td>{monthLabel(row.report_period)}</td><td>{row.geography_name}</td><td>{row.geography_level}</td><td>{row.property_type}</td><td>{row.metric_values?.sales??"—"}</td><td>{money(row.metric_values?.average_price)}</td><td>{money(row.metric_values?.median_price)}</td><td>{row.metric_values?.new_listings??"—"}</td><td>{row.metric_values?.days_on_market??"—"}</td></tr>)}
    {!agentRows.length&&<tr><td colSpan="9">No approved Market Watch statistics are currently available.</td></tr>}
   </tbody></table></div>
  </section>
 </div>;
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
      <td><div className="actions"><button className="secondary" onClick={()=>setSelectedId(r.id)}><Eye size={14}/> Review</button>{r.pdf_storage_path&&<button className="secondary" onClick={()=>openPdf(r)}><ExternalLink size={14}/> PDF</button>}</div></td>
     </tr>)}
     {!visibleReports.length&&<tr><td colSpan="5">No reports match this filter.</td></tr>}</tbody>
    </table>
   </div>
  </section>
  {selected&&<section className="panel" style={{marginTop:14}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:12,flexWrap:"wrap"}}>
    <div><h2 style={{marginBottom:4}}>{monthLabel(selected.report_period)} — Review</h2><p className="muted" style={{margin:0}}>Source: {selected.pdf_file_name||selected.source_name||"PDF not attached"} · {rows.length} extracted rows</p></div>
    <div className="actions">{selected.pdf_storage_path&&<button className="secondary" onClick={()=>openPdf(selected)}><FileText size={15}/> Open Original PDF</button>}
     {management&&String(selected.report_period).slice(0,7)==="2026-03"&&<button className="secondary" disabled={busy} onClick={()=>returnToReview(selected)}><ShieldAlert size={15}/> Move to Review</button>}
     {management&&selected.status!=="APPROVED"&&<button className="primary" disabled={busy||!rows.length||rows.some(x=>x.review_status!=="APPROVED")} onClick={()=>approveReport(selected)}>Approve & Publish</button>}
    </div>
   </div>
   {management&&rows.length>0&&<p className="muted" style={{marginTop:12}}>Check the original PDF page against each extracted row. Use Approve on a row only after confirming its geography, property type and figures.</p>}
   <div className="tablewrap" style={{marginTop:12,maxHeight:560,overflow:"auto"}}>
    <table><thead><tr><th>Page</th><th>Geography</th><th>Level</th><th>Property type</th><th>Sales</th><th>Avg. price</th><th>Median</th><th>New listings</th><th>DOM</th><th>Review</th></tr></thead>
     <tbody>{rows.map(row=><tr key={row.id}><td>{row.source_page||"—"}</td><td>{row.geography_name}</td><td>{row.geography_level}</td><td>{row.property_type}</td><td>{row.metric_values?.sales??"—"}</td><td>{money(row.metric_values?.average_price)}</td><td>{money(row.metric_values?.median_price)}</td><td>{row.metric_values?.new_listings??"—"}</td><td>{row.metric_values?.days_on_market??"—"}</td><td>{row.review_status==="APPROVED"?<span style={{color:"#167447"}}>Approved</span>:management?<button className="secondary" disabled={busy} onClick={()=>approveRow(row)}>Approve row</button>:"Pending"}</td></tr>)}
     {!rows.length&&<tr><td colSpan="10">No extracted detail rows are attached to this report. It cannot be published until extraction and validation are complete.</td></tr>}</tbody>
    </table>
   </div>
   {String(selected.report_period).slice(0,7)==="2026-03"&&<div className="notice" style={{marginTop:12,borderColor:"#d97706"}}><ShieldAlert size={17}/> March 2026 is excluded from agent access while its 319 extracted rows are being rechecked. The source PDF and rows remain intact.</div>}
  </section>}
 </div>;
}
