import {useCallback,useState} from "react";
import {AlertTriangle,CheckCircle2,Database,Download,FileArchive,RefreshCw,ShieldCheck} from "lucide-react";
import {supabase} from "./lib/supabase";
import LegacyChartMapping from "./LegacyChartMapping";

const SOURCE_TARGETS=[
  {key:"listings",label:"Legacy Listings",source:"dv_listings",target:"dv_accounting_listings",targetLabel:"New Listings"},
  {key:"trades",label:"Legacy Trade Sheets",source:"dv_deals",target:"dv_accounting_transactions",targetLabel:"New Transactions"},
  {key:"ap",label:"Legacy A/P Invoices",source:"dv_ap_invoices",target:"dv_accounting_expenses",targetLabel:"New Expenses"},
  {key:"documents",label:"Legacy Document Records",source:"dv_documents",target:"dv_accounting_listing_documents + dv_accounting_transaction_documents",targetTables:["dv_accounting_listing_documents","dv_accounting_transaction_documents"],targetLabel:"New Document Records"}
];
const BUCKETS=["dv-trade-documents","dv-vendor-invoices","dv-personnel"];
async function countRows(table){
  const {count,error}=await supabase.from(table).select("id",{count:"exact",head:true});
  if(error)return {count:null,error:error.message};
  return {count:count??0,error:null};
}
async function listBucketFiles(bucket){
  const files=[];const visited=new Set();
  async function walk(prefix="",depth=0){
    if(depth>8||visited.has(prefix))return;
    visited.add(prefix);
    let offset=0;
    while(true){
      const {data,error}=await supabase.storage.from(bucket).list(prefix,{limit:100,offset,sortBy:{column:"name",order:"asc"}});
      if(error)throw new Error(error.message);
      const items=data||[];
      for(const item of items){
        const path=prefix?prefix+"/"+item.name:item.name;
        if(item.id===null||(!item.metadata&&!item.id)){
          await walk(path,depth+1);
        }else{
          files.push({bucket,path,name:item.name,size:item.metadata?.size??null,mimeType:item.metadata?.mimetype??null,createdAt:item.created_at??null});
        }
      }
      if(items.length<100)break;
      offset+=items.length;
    }
  }
  await walk();
  return files;
}
function downloadJson(report){
  const blob=new Blob([JSON.stringify(report,null,2)],{type:"application/json"});
  const url=URL.createObjectURL(blob);const a=document.createElement("a");
  a.href=url;a.download="dv-legacy-migration-preflight.json";a.click();URL.revokeObjectURL(url);
}
export default function LegacyMigration({user,role}){
  const [loading,setLoading]=useState(false),[error,setError]=useState(""),[report,setReport]=useState(null),[activeTab,setActiveTab]=useState("scan");
  const isSuperAdmin=String(role||"").toUpperCase()==="SUPERADMIN";
  const scan=useCallback(async()=>{
    if(!supabase){setError("Supabase is not configured. No scan was run.");return}
    if(!isSuperAdmin){setError("Only Super Admin can access migration tools.");return}
    setLoading(true);setError("");
    try{
      const rows=await Promise.all(SOURCE_TARGETS.map(async item=>{
        const source=await countRows(item.source);
        const targets= item.targetTables||[item.target];
        const targetResults=await Promise.all(targets.map(countRows));
        return {...item,sourceCount:source.count,sourceError:source.error,targetCount:targetResults.some(x=>x.count===null)?null:targetResults.reduce((n,x)=>n+(x.count||0),0),targetError:targetResults.find(x=>x.error)?.error||null};
      }));
      const buckets=await Promise.all(BUCKETS.map(async bucket=>{
        try{const files=await listBucketFiles(bucket);return {bucket,count:files.length,files,error:null}}
        catch(e){return {bucket,count:null,files:[],error:e?.message||String(e)}}
      }));
      const createdAt=new Date().toISOString();
      const next={createdAt,projectUrl:import.meta.env.VITE_SUPABASE_URL||null,scannedBy:user?.email||user?.id||"unknown",rows,buckets,safety:{readOnly:true,recordsWritten:0,sourceModified:false,filesCopied:false}};
      setReport(next);
    }catch(e){setError(e?.message||"Preflight scan failed.")}
    finally{setLoading(false)}
  },[isSuperAdmin,user?.email,user?.id]);
  if(!isSuperAdmin)return <section className="panel"><h2>Access restricted</h2><p>Only Super Admin can access migration tools.</p></section>;
  const totalFiles=report?.buckets?.reduce((n,b)=>n+(b.count||0),0)??0;
  const sourceRecords=report?.rows?.reduce((n,r)=>n+(r.sourceCount||0),0)??0;
  return <div className="workspace" style={{display:"grid",gap:18}}>
    <div style={{display:"flex",gap:8,flexWrap:"wrap"}}>
      <button className={activeTab==="scan"?"primary":"secondary"} onClick={()=>setActiveTab("scan")}>Migration preflight</button>
      <button className={activeTab==="accounts"?"primary":"secondary"} onClick={()=>setActiveTab("accounts")}>Chart of Accounts mapping</button>
    </div>
    {activeTab==="accounts"&&<LegacyChartMapping user={user}/>}
    {activeTab==="scan"&&<>
    <section className="panel" style={{padding:22}}>
      <div style={{display:"flex",gap:12,alignItems:"center",marginBottom:10}}>
        <div style={{background:"#0f2141",color:"#9e8556",width:46,height:46,borderRadius:12,display:"grid",placeItems:"center"}}><Database size={24}/></div>
        <div><h2 style={{margin:"0 0 4px"}}>Legacy Data Migration</h2><div style={{color:"var(--muted,#667085)",fontSize:13}}>Old DV Back Office → DV Real Estate Accounting</div></div>
      </div>
      <p>Run a read-only inventory before importing historical listings, trade sheets, expenses, and original documents. This screen never changes the old system, creates accounting entries, or moves files.</p>
      <div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"center"}}>
        <button className="primary" onClick={scan} disabled={loading}><RefreshCw size={16} style={{marginRight:7,verticalAlign:"middle"}}/>{loading?"Scanning source tables and files…":"Run pre-migration scan"}</button>
        {report&&<button onClick={()=>downloadJson(report)}><Download size={16} style={{marginRight:7,verticalAlign:"middle"}}/>Download scan report</button>}
      </div>
      {error&&<div className="error" style={{marginTop:12}}>{error}</div>}
    </section>
    {report&&<>
      <section className="panel" style={{padding:20}}>
        <div style={{display:"flex",alignItems:"center",gap:9,marginBottom:8}}><ShieldCheck size={21} color="#198754"/><h3 style={{margin:0}}>Preflight completed — read-only</h3></div>
        <p style={{margin:"0 0 12px",color:"var(--muted,#667085)"}}>Scanned {new Date(report.createdAt).toLocaleString()} · {sourceRecords} legacy database records found across the checked source tables · {totalFiles} files inventoried in private storage.</p>
        <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(150px,1fr))",gap:10}}>
          <div style={{border:"1px solid var(--border,#e5e7eb)",borderRadius:10,padding:12}}><div style={{fontSize:12,color:"var(--muted,#667085)"}}>Legacy records</div><strong style={{fontSize:24}}>{sourceRecords}</strong></div>
          <div style={{border:"1px solid var(--border,#e5e7eb)",borderRadius:10,padding:12}}><div style={{fontSize:12,color:"var(--muted,#667085)"}}>Storage files</div><strong style={{fontSize:24}}>{totalFiles}</strong></div>
          <div style={{border:"1px solid var(--border,#e5e7eb)",borderRadius:10,padding:12}}><div style={{fontSize:12,color:"var(--muted,#667085)"}}>Rows/files changed</div><strong style={{fontSize:24}}>0</strong></div>
        </div>
      </section>
      <section className="panel" style={{padding:20}}>
        <h3 style={{marginTop:0}}>Database source-to-target inventory</h3>
        <div style={{overflowX:"auto"}}>
          <table style={{width:"100%",borderCollapse:"collapse",fontSize:13}}>
            <thead><tr><th style={{textAlign:"left",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>Category</th><th style={{textAlign:"left",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>Legacy source</th><th style={{textAlign:"right",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>Source rows</th><th style={{textAlign:"left",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>New target</th><th style={{textAlign:"right",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>Target rows</th><th style={{textAlign:"left",padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>Preflight</th></tr></thead>
            <tbody>{report.rows.map(r=><tr key={r.key}>
              <td style={{padding:10,borderBottom:"1px solid var(--border,#e5e7eb)",fontWeight:600}}>{r.label}</td>
              <td style={{padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}><code>{r.source}</code>{r.sourceError&&<div className="error">{r.sourceError}</div>}</td>
              <td style={{padding:10,textAlign:"right",borderBottom:"1px solid var(--border,#e5e7eb)"}}>{r.sourceCount??"Unavailable"}</td>
              <td style={{padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}><code>{r.target}</code>{r.targetError&&<div className="error">{r.targetError}</div>}</td>
              <td style={{padding:10,textAlign:"right",borderBottom:"1px solid var(--border,#e5e7eb)"}}>{r.targetCount??"Unavailable"}</td>
              <td style={{padding:10,borderBottom:"1px solid var(--border,#e5e7eb)"}}>{r.sourceError||r.targetError?<span style={{color:"#b42318"}}>Check access/schema</span>:r.sourceCount===0?<span style={{color:"#b54708"}}>No source rows found</span>:<span style={{color:"#027a48"}}>Source data found</span>}</td>
            </tr>)}</tbody>
          </table>
        </div>
      </section>
      <section className="panel" style={{padding:20}}>
        <h3 style={{marginTop:0}}>Original document storage inventory</h3>
        <p style={{color:"var(--muted,#667085)"}}>Files are counted in place. No private file is downloaded, copied, deleted, or made public during this scan.</p>
        {report.buckets.map(b=><div key={b.bucket} style={{display:"flex",justifyContent:"space-between",gap:12,padding:"10px 0",borderBottom:"1px solid var(--border,#e5e7eb)"}}><div><strong>{b.bucket}</strong>{b.error&&<div className="error">{b.error}</div>}</div><strong>{b.count===null?"Unavailable":b.count+" files"}</strong></div>)}
      </section>
      {report.rows.some(r=>r.sourceCount===0)||report.buckets.some(b=>b.error)?<section className="panel" style={{padding:18,border:"1px solid #fdb022"}}>
        <div style={{display:"flex",gap:9,alignItems:"flex-start"}}><AlertTriangle color="#b54708" size={22}/><div><strong>Do not run a partial import yet</strong><p style={{margin:"6px 0 0"}}>At least one legacy source table is empty or unavailable. Confirm that the old app points to this database and check the scan report before importing. A zero count is not proof that the records do not exist elsewhere.</p></div></div>
      </section>:<section className="panel" style={{padding:18}}>
        <div style={{display:"flex",gap:9,alignItems:"flex-start"}}><CheckCircle2 color="#027a48" size={22}/><div><strong>Source inventory is available</strong><p style={{margin:"6px 0 0"}}>The next stage is to preview the field mapping and duplicates, then import in a controlled batch with historical statuses preserved and no automatic posting or payments.</p></div></div>
      </section>}
    </>}
    <section className="panel" style={{padding:18,background:"var(--panel,#fff)"}}>
      <h3 style={{marginTop:0}}>Migration safeguards</h3>
      <ul style={{marginBottom:0,lineHeight:1.7}}>
        <li>Old Back Office records and files remain untouched.</li>
        <li>Existing new-app records are counted before any import.</li>
        <li>Historical trades must not trigger commission payments, cheques, trust movements, or journal postings.</li>
        <li>Original files stay private; they are linked only after their record and ownership are verified.</li>
        <li>Duplicate detection and a migration audit log are required before the import stage is enabled.</li>
      </ul>
    </section>
    </>}
  </div>
}
