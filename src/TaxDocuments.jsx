import React,{useCallback,useEffect,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,FileText,Download,Lock,Eye,Printer,X,ExternalLink} from "lucide-react";

export default function TaxDocuments(){
 const [year,setYear]=useState(new Date().getFullYear()-1),[slips,setSlips]=useState([]),[busy,setBusy]=useState(false),[opening,setOpening]=useState(null),[downloading,setDownloading]=useState(null),[error,setError]=useState(""),[preview,setPreview]=useState(null);
 const load=useCallback(async()=>{
  if(!supabase){setSlips([]);return}
  setBusy(true);setError("");
  try{
   const {data,error}=await supabase.from("dv_accounting_tax_slips").select("id,tax_year,slip_type,status,original_filename,storage_path,file_size_bytes,updated_at").eq("tax_year",Number(year)).eq("status","released").not("storage_path","is",null).order("slip_type");
   if(error)throw error;setSlips(data||[]);
  }catch(e){setError(e?.message||"Could not load your tax documents.");setSlips([])}
  finally{setBusy(false)}
 },[year]);
 useEffect(()=>{load()},[load]);
 const signedUrl=async(slip,download=false)=>{
  const options=download?{download:slip.original_filename||true}:{};
  const {data,error}=await supabase.storage.from("dv-tax-slips").createSignedUrl(slip.storage_path,300,options);
  if(error)throw error;if(!data?.signedUrl)throw new Error("A secure document link could not be created.");
  return data.signedUrl;
 };
 const openPreview=async slip=>{
  if(!supabase||!slip.storage_path)return;setOpening(slip.id);setError("");
  try{const url=await signedUrl(slip);setPreview({...slip,url})}
  catch(e){setError(e?.message||"Could not preview this document.")}
  finally{setOpening(null)}
 };
 const download=async slip=>{
  if(!supabase||!slip.storage_path)return;setDownloading(slip.id);setError("");
  try{const url=await signedUrl(slip,true);window.location.assign(url)}
  catch(e){setError(e?.message||"Could not download this document.")}
  finally{setDownloading(null)}
 };
 const printPreview=()=>{
  if(!preview?.url)return;
  const w=window.open(preview.url,"_blank","noopener,noreferrer");
  if(!w)setError("Your browser blocked the preview tab. Allow pop-ups for this site, then use Preview again.");
 };
 return <div className="page">
  <div className="pagehead"><div><h1>My Tax Documents</h1><p className="muted">Preview, print, or save T4 and T4A PDFs released to your account.</p></div><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
  <section className="panel">
   <label>Tax year<select value={year} onChange={e=>{setYear(Number(e.target.value));setPreview(null)}} style={{display:"block",padding:9,minWidth:150,marginTop:6}}>{Array.from({length:8},(_,i)=>new Date().getFullYear()-i).map(y=><option key={y} value={y}>{y}</option>)}</select></label>
   {error&&<p role="alert" style={{color:"#b42318",marginTop:12,overflowWrap:"anywhere"}}>{error}</p>}
   {slips.length?<div style={{marginTop:18,display:"grid",gap:12}}>{slips.map(slip=><div key={slip.id} style={{border:"1px solid #e4e7ec",borderRadius:10,padding:16,display:"flex",justifyContent:"space-between",alignItems:"center",gap:14,flexWrap:"wrap"}}><div><strong><FileText size={18} style={{verticalAlign:"middle",marginRight:8}}/>{slip.slip_type} — {slip.tax_year}</strong><div className="muted" style={{marginTop:6}}>{slip.original_filename||"Tax document PDF"}{slip.file_size_bytes?" · "+Math.ceil(slip.file_size_bytes/1024)+" KB":""}</div><div className="muted" style={{marginTop:4}}>Released{slip.updated_at?" · Updated "+new Date(slip.updated_at).toLocaleDateString():""}</div></div><div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button className="secondary" onClick={()=>openPreview(slip)} disabled={!!opening}><Eye size={16}/>{opening===slip.id?" Preparing…":"Preview"}</button><button className="secondary" onClick={()=>download(slip)} disabled={!!downloading}><Download size={16}/>{downloading===slip.id?" Preparing…":"Download PDF"}</button></div></div>)}</div>
    :<div style={{padding:"30px 12px",textAlign:"center"}}><FileText size={32} style={{opacity:.55}}/><h3 style={{margin:"10px 0 6px"}}>{busy?"Loading tax documents…":"No tax PDFs available for "+year}</h3><p className="muted" style={{margin:0}}>When the brokerage uploads and releases your T4 or T4A, it will appear here.</p></div>}
   <p className="muted" style={{marginTop:16,fontSize:13}}><Lock size={14} style={{verticalAlign:"middle",marginRight:5}}/>Documents are stored privately. Only released documents assigned to your account are listed.</p>
  </section>
  {preview&&<div role="dialog" aria-modal="true" aria-label={preview.slip_type+" preview"} style={{position:"fixed",inset:0,zIndex:1000,background:"rgba(15,23,42,.72)",display:"flex",alignItems:"center",justifyContent:"center",padding:16}}>
   <section style={{background:"var(--panel,#fff)",borderRadius:12,width:"min(1100px,100%)",height:"min(90vh,900px)",display:"flex",flexDirection:"column",overflow:"hidden",boxShadow:"0 20px 60px rgba(0,0,0,.3)"}}>
    <header style={{display:"flex",alignItems:"center",justifyContent:"space-between",gap:12,padding:"12px 16px",borderBottom:"1px solid #e4e7ec",flexWrap:"wrap"}}>
     <div><strong>{preview.slip_type} — {preview.tax_year}</strong><div className="muted" style={{fontSize:12,marginTop:3}}>{preview.original_filename||"Tax document PDF"}</div></div>
     <div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button className="secondary" onClick={printPreview}><Printer size={16}/> Print / Save PDF</button><button className="secondary" onClick={()=>download(preview)} disabled={!!downloading}><Download size={16}/> Download</button><button className="secondary" aria-label="Close preview" onClick={()=>setPreview(null)}><X size={16}/> Close</button></div>
    </header>
    <div style={{flex:1,minHeight:0,background:"#525659"}}><iframe title={preview.slip_type+" "+preview.tax_year+" PDF preview"} src={preview.url} style={{width:"100%",height:"100%",border:0,background:"#fff"}} /></div>
    <footer className="muted" style={{padding:"8px 16px",fontSize:12,borderTop:"1px solid #e4e7ec"}}><ExternalLink size={13} style={{verticalAlign:"middle",marginRight:5}}/>Print / Save PDF opens the secure PDF in a new tab. Use your browser’s print dialog and choose “Save as PDF” if you want a saved copy.</footer>
   </section>
  </div>}
 </div>
}
