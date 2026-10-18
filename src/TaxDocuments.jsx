import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,FileText,Download,Lock} from "lucide-react";

export default function TaxDocuments(){
 const [year,setYear]=useState(new Date().getFullYear()-1),[slips,setSlips]=useState([]),[busy,setBusy]=useState(false),[downloading,setDownloading]=useState(null),[error,setError]=useState("");
 const load=useCallback(async()=>{
  if(!supabase){setSlips([]);return}
  setBusy(true);setError("");
  try{
   // Row-level security limits this query to documents released to the signed-in recipient.
   const {data,error}=await supabase.from("dv_accounting_tax_slips").select("id,tax_year,slip_type,status,original_filename,storage_path,file_size_bytes,updated_at").eq("tax_year",Number(year)).eq("status","released").not("storage_path","is",null).order("slip_type");
   if(error)throw error;setSlips(data||[]);
  }catch(e){setError(e?.message||"Could not load your tax documents.");setSlips([])}
  finally{setBusy(false)}
 },[year]);
 useEffect(()=>{load()},[load]);
 const download=async slip=>{
  if(!supabase||!slip.storage_path)return;setDownloading(slip.id);setError("");
  try{
   const {data,error}=await supabase.storage.from("dv-tax-slips").createSignedUrl(slip.storage_path,60,{download:slip.original_filename||true});
   if(error)throw error;if(!data?.signedUrl)throw new Error("A secure download link could not be created.");
   window.location.assign(data.signedUrl);
  }catch(e){setError(e?.message||"Could not download this document.")}finally{setDownloading(null)}
 };
 return <div className="page">
  <div className="pagehead"><div><h1>My Tax Documents</h1><p className="muted">Download T4 and T4A PDFs that Dream Valley Realty has released to your account.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
  <section className="panel">
   <label>Tax year<select value={year} onChange={e=>setYear(Number(e.target.value))} style={{display:"block",padding:9,minWidth:150,marginTop:6}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label>
   {error&&<p role="alert" style={{color:"#b42318",marginTop:12,overflowWrap:"anywhere"}}>{error}</p>}
   {slips.length?<div style={{marginTop:18,display:"grid",gap:12}}>{slips.map(slip=><div key={slip.id} style={{border:"1px solid #e4e7ec",borderRadius:10,padding:16,display:"flex",justifyContent:"space-between",alignItems:"center",gap:14,flexWrap:"wrap"}}><div><strong><FileText size={18} style={{verticalAlign:"middle",marginRight:8}}/>{slip.slip_type} — {slip.tax_year}</strong><div className="muted" style={{marginTop:6}}>{slip.original_filename||"Tax document PDF"}{slip.file_size_bytes?" · "+Math.ceil(slip.file_size_bytes/1024)+" KB":""}</div><div className="muted" style={{marginTop:4}}>Released{slip.updated_at?" · Updated "+new Date(slip.updated_at).toLocaleDateString():""}</div></div><button className="primary" onClick={()=>download(slip)} disabled={!!downloading}><Download size={16}/>{downloading===slip.id?" Preparing…":"Download PDF"}</button></div>)}</div>
    :<div style={{padding:"30px 12px",textAlign:"center"}}><FileText size={32} style={{opacity:.55}}/><h3 style={{margin:"10px 0 6px"}}>{busy?"Loading tax documents…":"No tax PDFs available for "+year}</h3><p className="muted" style={{margin:0}}>When the brokerage uploads and releases your T4 or T4A, it will appear here.</p></div>}
   <p className="muted" style={{marginTop:16,fontSize:13}}><Lock size={14} style={{verticalAlign:"middle",marginRight:5}}/>Documents are stored privately. Only released documents assigned to your account are listed.</p>
  </section>
 </div>
}