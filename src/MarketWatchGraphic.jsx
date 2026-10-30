import React,{useCallback,useEffect,useMemo,useRef,useState} from "react";
import {supabase} from "./lib/supabase";
import {Download,RefreshCw,Image as ImageIcon,AlertCircle,CheckCircle2} from "lucide-react";

const NAVY="#061c34",GOLD="#c9973c",WHITE="#ffffff";
const monthLabel=value=>value?new Date(value+"T00:00:00").toLocaleDateString("en-CA",{month:"long",year:"numeric"}):"";
const fmtInt=value=>value==null||value===""?"—":new Intl.NumberFormat("en-CA",{maximumFractionDigits:0}).format(Number(value));
const fmtMoney=value=>value==null||value===""?"—":new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD",maximumFractionDigits:0}).format(Number(value));
const metricKeys={sales:["sales","units_sold"],new_listings:["new_listings"],active_listings:["active_listings"],average_price:["average_price","avg_price"],days_on_market:["days_on_market","avg_dom","ldom"]};
const readMetric=(row,key)=>{for(const k of metricKeys[key]||[key]){const v=row?.metric_values?.[k];if(v!==null&&v!==undefined&&v!=="")return Number(v);}return null;};
const percent=(current,previous)=>current==null||previous==null||previous===0?null:((current-previous)/previous)*100;
const safeImage=src=>new Promise(resolve=>{if(!src){resolve(null);return;}const img=new Image();img.crossOrigin="anonymous";img.onload=()=>resolve(img);img.onerror=()=>resolve(null);img.src=src;});
const rounded=(ctx,x,y,w,h,r,fill,stroke)=>{ctx.beginPath();ctx.roundRect(x,y,w,h,r);if(fill){ctx.fillStyle=fill;ctx.fill();}if(stroke){ctx.strokeStyle=stroke;ctx.lineWidth=2;ctx.stroke();}};
const drawText=(ctx,text,x,y,size,color,weight="normal",font="Arial",align="left")=>{ctx.font=weight+" "+size+"px "+font;ctx.fillStyle=color;ctx.textAlign=align;ctx.fillText(String(text??""),x,y);};
const drawCircleIcon=(ctx,cx,cy,symbol)=>{ctx.beginPath();ctx.arc(cx,cy,39,0,Math.PI*2);ctx.fillStyle=NAVY;ctx.fill();ctx.strokeStyle=GOLD;ctx.lineWidth=3;ctx.stroke();drawText(ctx,symbol,cx,cy+12,37,GOLD,"bold","Arial","center");};
function drawBarPair(ctx,x,y,w,h,current,previous,currentLabel,previousLabel,maxValue,format){
 const base=y+h;ctx.strokeStyle="#d8dde4";ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(x,base);ctx.lineTo(x+w,base);ctx.stroke();
 const max=Math.max(Number(current)||0,Number(previous)||0,maxValue||0,1)*1.08;
 const barW=42,gap=28,b1=x+(w-(barW*2+gap))/2,b2=b1+barW+gap;
 const h1=Math.max(2,(Number(current)||0)/max*(h-22)),h2=Math.max(2,(Number(previous)||0)/max*(h-22));
 ctx.fillStyle=NAVY;ctx.fillRect(b1,base-h1,barW,h1);ctx.fillStyle=GOLD;ctx.fillRect(b2,base-h2,barW,h2);
 drawText(ctx,format(current),b1+barW/2,base-h1-9,15,NAVY,"bold","Arial","center");
 drawText(ctx,format(previous),b2+barW/2,base-h2-9,15,NAVY,"bold","Arial","center");
 drawText(ctx,currentLabel,b1+barW/2,base+21,12,NAVY,"normal","Arial","center");
 drawText(ctx,previousLabel,b2+barW/2,base+21,12,NAVY,"normal","Arial","center");
}
function drawGraphic(canvas,data,agent,headshot,logo){
 const ctx=canvas.getContext("2d");if(!ctx)return;
 const W=1400,H=1120;canvas.width=W;canvas.height=H;
 const bg=ctx.createLinearGradient(0,0,W,H);bg.addColorStop(0,"#f8f8f6");bg.addColorStop(1,"#e9edf0");ctx.fillStyle=bg;ctx.fillRect(0,0,W,H);
 ctx.fillStyle=NAVY;ctx.fillRect(0,0,W,192);
 ctx.fillStyle=GOLD;ctx.fillRect(0,190,W,5);
 drawText(ctx,"MARKET",52,99,66,WHITE,"bold","Georgia");drawText(ctx,"WATCH",354,99,66,"#e5b85f","bold","Georgia");
 drawText(ctx,monthLabel(data.report.report_period),198,148,32,WHITE,"normal","Georgia","center");
 ctx.fillStyle=GOLD;ctx.fillRect(54,158,130,2);ctx.fillRect(452,158,155,2);
 drawText(ctx,"YEAR-OVER-YEAR SUMMARY",652,83,19,"#e5b85f","bold","Georgia");
 drawText(ctx,"ALL TRREB AREAS · ALL HOME TYPES",652,111,14,WHITE,"normal","Georgia");
 if(logo){const maxW=315,maxH=122,scale=Math.min(maxW/logo.width,maxH/logo.height);ctx.drawImage(logo,1030,26,logo.width*scale,logo.height*scale);}
 else{drawText(ctx,"DV",1075,112,65,GOLD,"bold","Georgia");drawText(ctx,"DREAM VALLEY",1150,79,24,WHITE,"normal","Georgia");drawText(ctx,"REALTY",1185,108,20,WHITE,"normal","Georgia");}
 const curLabel=monthLabel(data.report.report_period),prevLabel=data.previous?monthLabel(data.previous.report_period):"Prior year";
 const cards=[
  {x:40,y:210,w:430,h:350,key:"sales",title:"SOLD",sub:"Units Sold",symbol:"⌂",format:fmtInt},
  {x:485,y:210,w:430,h:350,key:"new_listings",title:"NEW LISTINGS",sub:"New Listings",symbol:"⌂",format:fmtInt},
  {x:930,y:210,w:430,h:350,key:"active_listings",title:"ACTIVE LISTINGS",sub:"Active Listings",symbol:"▤",format:fmtInt}
 ];
 for(const card of cards){
  rounded(ctx,card.x,card.y,card.w,card.h,20,WHITE,GOLD);
  drawCircleIcon(ctx,card.x+67,card.y+63,card.symbol);
  drawText(ctx,card.title,card.x+132,card.y+52,25,NAVY,"bold","Georgia");
  drawText(ctx,card.format(data.values[card.key]),card.x+132,card.y+115,52,NAVY,"bold","Georgia");
  drawText(ctx,card.sub,card.x+34,card.y+151,19,NAVY,"normal","Georgia");
  const change=percent(data.values[card.key],data.previousValues[card.key]);
  rounded(ctx,card.x+25,card.y+204,160,94,12,"#fff",change==null?"#9aa4b2":change<=0?"#d83a37":"#b5c3b7");
  drawText(ctx,change==null?"N/A":(change>0?"+":"")+change.toFixed(1)+"%",card.x+105,card.y+259,34,change==null?"#64748b":change<=0?"#d83a37":"#187344","bold","Georgia","center");
  drawText(ctx,"YEAR-OVER-YEAR",card.x+105,card.y+282,11,NAVY,"bold","Georgia","center");
  drawBarPair(ctx,card.x+205,card.y+190,205,122,data.values[card.key],data.previousValues[card.key],curLabel,prevLabel,0,card.format);
 }
 rounded(ctx,36,580,650,318,20,NAVY,null);
 drawCircleIcon(ctx,106,652,"$");
 drawText(ctx,"AVERAGE PRICE",176,640,32,"#e5b85f","bold","Georgia");
 drawText(ctx,fmtMoney(data.values.average_price),176,711,58,WHITE,"normal","Georgia");
 drawText(ctx,"Average Selling Price",176,751,22,WHITE,"normal","Georgia");
 const priceChange=percent(data.values.average_price,data.previousValues.average_price);
 rounded(ctx,175,790,220,78,12,NAVY,priceChange==null?"#8b98a8":priceChange<=0?"#d83a37":"#4d9a6d");
 drawText(ctx,priceChange==null?"N/A":(priceChange>0?"+":"")+priceChange.toFixed(1)+"%",285,844,43,priceChange==null?"#cbd5e1":priceChange<=0?"#ef4444":"#75c893","bold","Georgia","center");
 drawBarPair(ctx,420,665,235,155,data.values.average_price,data.previousValues.average_price,curLabel,prevLabel,0,fmtMoney);
 rounded(ctx,704,580,660,318,20,WHITE,GOLD);
 drawCircleIcon(ctx,778,652,"◷");
 drawText(ctx,"AVERAGE DOM",850,640,32,"#a77a2c","bold","Georgia");
 drawText(ctx,fmtInt(data.values.days_on_market),850,715,62,NAVY,"normal","Georgia");
 drawText(ctx,"Avg. DOM (Listing Days on Market)",850,752,20,NAVY,"normal","Georgia");
 const domChange=percent(data.values.days_on_market,data.previousValues.days_on_market);
 rounded(ctx,850,790,205,78,12,WHITE,domChange==null?"#9aa4b2":domChange>=0?"#187344":"#d83a37");
 drawText(ctx,domChange==null?"N/A":(domChange>0?"+":"")+domChange.toFixed(1)+"%",952,844,43,domChange==null?"#64748b":domChange>=0?"#187344":"#d83a37","bold","Georgia","center");
 drawBarPair(ctx,1080,665,245,155,data.values.days_on_market,data.previousValues.days_on_market,curLabel,prevLabel,0,fmtInt);
 ctx.fillStyle=NAVY;ctx.fillRect(0,950,W,170);ctx.fillStyle=GOLD;ctx.fillRect(0,948,W,4);
 ctx.beginPath();ctx.arc(120,1019,79,0,Math.PI*2);ctx.fillStyle=WHITE;ctx.fill();ctx.lineWidth=5;ctx.strokeStyle=GOLD;ctx.stroke();
 if(headshot){ctx.save();ctx.beginPath();ctx.arc(120,1019,71,0,Math.PI*2);ctx.clip();const scale=Math.max(142/headshot.width,142/headshot.height);const sw=142/scale,sh=142/scale;ctx.drawImage(headshot,(headshot.width-sw)/2,(headshot.height-sh)/2,sw,sh,49,948,142,142);ctx.restore();}
 else{drawText(ctx,(agent.name||"Agent").split(/\s+/).map(x=>x[0]).slice(0,2).join("").toUpperCase(),120,1031,38,NAVY,"bold","Arial","center");}
 drawText(ctx,agent.name||"Agent",250,1000,34,"#e5b85f","bold","Georgia");
 drawText(ctx,agent.title||"REALTOR®",250,1032,17,WHITE,"normal","Georgia");
 drawText(ctx,agent.phone||"",250,1070,18,WHITE,"normal","Arial");
 drawText(ctx,agent.email||"",520,1070,18,WHITE,"normal","Arial");
 drawText(ctx,"dreamvalleyrealty.ca",990,1070,18,WHITE,"normal","Arial");
 drawText(ctx,"GUIDING YOU HOME, EVERY STEP OF THE WAY.",700,1110,13,"#e5b85f","normal","Georgia","center");
 drawText(ctx,"SOURCE: TRREB MARKET WATCH · "+curLabel.toUpperCase(),700,928,14,NAVY,"bold","Georgia","center");
}
export default function MarketWatchGraphic({agentId,user}){
 const canvasRef=useRef(null);
 const [allRows,setAllRows]=useState([]),[agent,setAgent]=useState(null),[headshotUrl,setHeadshotUrl]=useState(""),[selectedId,setSelectedId]=useState(""),[loading,setLoading]=useState(true),[error,setError]=useState(""),[notice,setNotice]=useState("");
 const load=useCallback(async()=>{
  if(!supabase){setError("Database connection is not configured.");setLoading(false);return;}
  setLoading(true);setError("");
  try{
   // Only published reports are available to agents. Row approval alone is not publication.
   const {data:publishedReports,error:reportsError}=await supabase.from("dv_property_market_reports").select("id,report_period,status").eq("status","APPROVED").order("report_period",{ascending:false});
   if(reportsError)throw reportsError;
   const safeReports=(publishedReports||[]).filter(r=>String(r.report_period).slice(0,7)!=="2026-03");
   const reportIds=safeReports.map(r=>r.id);
   let approvedRows=[];
   if(reportIds.length){
    const {data,error:rowsError}=await supabase.from("dv_property_market_stat_rows").select("*").in("market_report_id",reportIds).eq("review_status","APPROVED").order("report_period",{ascending:false});
    if(rowsError)throw rowsError;
    approvedRows=data||[];
   }
   const safeRows=approvedRows.filter(r=>String(r.report_period).slice(0,7)!=="2026-03");
   setAllRows(safeRows);
   const rowCounts=new Map();for(const row of safeRows)rowCounts.set(row.market_report_id,(rowCounts.get(row.market_report_id)||0)+1);
   const clean=safeReports.filter(report=>(rowCounts.get(report.id)||0)>0).map(report=>({...report,count:rowCounts.get(report.id)||0}));
   setSelectedId(old=>clean.some(r=>r.id===old)?old:(clean[0]?.id||""));
   let profileQuery=supabase.from("dv_accounting_agents").select("id,first_name,last_name,name,email,cell_phone,headshot_path");
   if(agentId)profileQuery=profileQuery.eq("id",agentId);else if(user?.email)profileQuery=profileQuery.ilike("email",user.email.trim());else throw new Error("Your agent profile could not be identified.");
   const {data:profile,error:profileError}=await profileQuery.maybeSingle();
   if(profileError)throw profileError;
   if(!profile)throw new Error("Your agent profile was not found. Please contact the office.");
   setAgent(profile);
   if(profile.headshot_path){const {data:photo,error:photoError}=await supabase.storage.from("dv-personnel").createSignedUrl(profile.headshot_path,3600);if(!photoError)setHeadshotUrl(photo?.signedUrl||"");}
  }catch(e){setError(e.message||"Unable to load Market Watch graphic data.");}
  finally{setLoading(false);}
 },[agentId,user?.email]);
 useEffect(()=>{load();},[load]);
 const reports=useMemo(()=>{const grouped=new Map();for(const row of allRows){const key=row.market_report_id;if(!grouped.has(key))grouped.set(key,{id:key,report_period:row.report_period,count:0});grouped.get(key).count++;}const choices=[...grouped.values()].sort((a,b)=>b.report_period.localeCompare(a.report_period)||b.count-a.count);const byMonth=new Map();for(const item of choices)if(!byMonth.has(item.report_period))byMonth.set(item.report_period,item);return [...byMonth.values()];},[allRows]);
 const selected=reports.find(r=>r.id===selectedId)||null;
 const comparison=useMemo(()=>{if(!selected)return null;const target=new Date(selected.report_period+"T00:00:00");target.setFullYear(target.getFullYear()-1);const key=target.toISOString().slice(0,10);return reports.find(r=>r.report_period===key)||null;},[reports,selected]);
 const findAllGtaRow=list=>list.find(r=>r.property_type==="ALL"&&(/all gta|all trreb areas|greater toronto area/i.test(r.geography_name||"")))||list.find(r=>r.property_type==="ALL"&&r.geography_level==="GTA")||null;
 const rows=useMemo(()=>allRows.filter(r=>r.market_report_id===selectedId),[allRows,selectedId]);
 const comparisonRows=useMemo(()=>comparison?allRows.filter(r=>r.market_report_id===comparison.id):[],[allRows,comparison]);
 const currentRow=findAllGtaRow(rows);
 const previousRow=findAllGtaRow(comparisonRows);
 const values=useMemo(()=>Object.fromEntries(Object.keys(metricKeys).map(k=>[k,readMetric(currentRow,k)])),[currentRow]);
 const previousValues=useMemo(()=>Object.fromEntries(Object.keys(metricKeys).map(k=>[k,readMetric(previousRow,k)])),[previousRow]);
 const canRender=!!selected&&!!currentRow&&Object.values(values).some(v=>v!==null);
 useEffect(()=>{
  let cancelled=false;
  if(!canRender||!agent||!canvasRef.current)return;
  Promise.all([safeImage(headshotUrl),safeImage("/dv-logo.svg")]).then(([head,logo])=>{if(cancelled)return;drawGraphic(canvasRef.current,{report:selected,previous:comparison,values,previousValues}, {name:agent.name||[agent.first_name,agent.last_name].filter(Boolean).join(" "),title:"REALTOR®",phone:agent.cell_phone||"",email:agent.email||""},head,logo);});
  return()=>{cancelled=true;};
 },[canRender,selected?.id,comparison?.id,JSON.stringify(values),JSON.stringify(previousValues),agent,headshotUrl]);
 const download=()=>{const canvas=canvasRef.current;if(!canvas)return;canvas.toBlob(blob=>{if(!blob){setError("The image could not be created. Please try again.");return;}const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download="Dream-Valley-Market-Watch-"+String(selected.report_period).slice(0,7)+"-"+(agent?.name||"Agent").replace(/[^a-z0-9]+/gi,"-")+".png";a.click();URL.revokeObjectURL(url);setNotice("Your Market Watch graphic has been downloaded.");},"image/png");};
 if(loading)return <section className="panel"><p>Loading your Market Watch graphic workspace…</p></section>;
 return <div className="market-watch-graphic">
  <section className="panel" style={{background:NAVY,color:WHITE,padding:22,marginBottom:16}}><div style={{color:"#e5b85f",fontSize:12,fontWeight:800,letterSpacing:2}}>DREAM VALLEY REALTY</div><h1 style={{margin:"8px 0 4px",fontSize:26}}>Market Watch Graphic</h1><p style={{margin:0,opacity:.85}}>Create a branded market update with your agent contact details.</p></section>
  {error&&<div className="notice" role="alert" style={{marginBottom:12,borderColor:"#d97706"}}><AlertCircle size={16}/>{error}</div>}
  {notice&&<div className="notice" role="status" style={{marginBottom:12}}><CheckCircle2 size={16}/>{notice}</div>}
  <section className="panel" style={{marginBottom:14}}>
   <div className="formgrid"><label>Approved Market Watch month<select value={selectedId} onChange={e=>{setSelectedId(e.target.value);setNotice("");}}><option value="">Select a report</option>{reports.map(r=><option key={r.id} value={r.id}>{monthLabel(r.report_period)}</option>)}</select></label><label>Agent profile<input value={agent?.name||[agent?.first_name,agent?.last_name].filter(Boolean).join(" ")||"Loading…"} readOnly/></label></div>
   <div className="actions" style={{marginTop:14}}><button type="button" className="secondary" onClick={load} ><RefreshCw size={15}/> Refresh reports</button><button type="button" className="primary" onClick={download} disabled={!canRender}><Download size={16}/> Download PNG</button></div>
   {!selected&&<p className="muted" style={{marginBottom:0}}>No approved Market Watch reports are currently available.</p>}
   {selected&&!currentRow&&<div className="notice" style={{marginTop:12}}>This report does not contain an approved All GTA / All TRREB Areas, All Home Types row. The graphic cannot be generated from incomplete data.</div>}
   {selected&&currentRow&&!comparison&&<p className="muted" style={{marginBottom:0}}>The matching month from the previous year is not approved yet. Year-over-year comparisons will display as unavailable.</p>}
  </section>
  <section className="panel"><div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap",marginBottom:12}}><div><h2 style={{margin:0}}>Graphic Preview</h2><p className="muted" style={{margin:"4px 0 0"}}>1400 × 1120 px · PNG format</p></div><ImageIcon size={22} color={GOLD}/></div>
   {canRender?<div style={{overflowX:"auto",background:"#e9edf0",padding:10,borderRadius:10}}><canvas ref={canvasRef} style={{display:"block",width:"100%",height:"auto",maxWidth:1100,margin:"0 auto",background:"#e9edf0"}}/></div>:<div className="notice">Select an approved report with complete GTA summary figures to preview the graphic.</div>}
  </section>
 </div>;
}
