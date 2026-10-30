import React,{useCallback,useEffect,useMemo,useRef,useState} from "react";
import {supabase} from "./lib/supabase";
import {Download,RefreshCw,Image as ImageIcon,AlertCircle,CheckCircle2} from "lucide-react";

const NAVY="#0f2141",GOLD="#9e8556",WHITE="#ffffff";
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
 const W=1402,H=1122;canvas.width=W;canvas.height=H;
 const navy="#0f2141",gold="#9e8556",cream="#f7f5ef",red="#e12626",green="#16713b";
 const curLabel=monthLabel(data.report.report_period),prevLabel=data.previous?monthLabel(data.previous.report_period):"Prior year";
 const changeFor=key=>percent(data.values[key],data.previousValues[key]);
 const formatFor=key=>key==="average_price"?fmtMoney:fmtInt;
 const drawRound=(x,y,w,h,r,fill,stroke=gold,lw=2)=>{ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}};
 const text=(value,x,y,size,color=navy,weight="normal",font="Georgia",align="left")=>drawText(ctx,value,x,y,size,color,weight,font,align);
 const line=(x1,y1,x2,y2,color=gold,width=2)=>{ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.strokeStyle=color;ctx.lineWidth=width;ctx.stroke();};
 const gradient=ctx.createLinearGradient(0,0,W,H);gradient.addColorStop(0,"#fbfaf6");gradient.addColorStop(1,"#e9edf0");ctx.fillStyle=gradient;ctx.fillRect(0,0,W,H);
 // Navy header with Toronto skyline silhouette.
 ctx.fillStyle=navy;ctx.fillRect(0,0,W,198);
 ctx.fillStyle="#0d2943";
 const skyline=[[850,132,18,62],[872,112,24,82],[900,145,16,49],[922,98,22,96],[950,126,16,68],[970,82,23,112],[1000,119,19,75],[1025,96,24,98],[1055,135,18,59],[1080,111,25,83],[1110,142,18,52],[1130,119,22,75],[1160,146,18,48]];
 skyline.forEach(([x,y,w,h])=>{ctx.fillRect(x,y,w,h);for(let wy=y+9;wy<y+h-5;wy+=13)for(let wx=x+5;wx<x+w-3;wx+=8){ctx.fillStyle="#29445c";ctx.fillRect(wx,wy,3,4);}ctx.fillStyle="#0d2943";});
 // CN Tower silhouette.
 line(896,48,896,150,"#29445c",3);line(888,79,904,79,"#29445c",3);line(891,64,901,64,"#29445c",2);ctx.beginPath();ctx.moveTo(896,48);ctx.lineTo(891,67);ctx.lineTo(901,67);ctx.closePath();ctx.fillStyle="#29445c";ctx.fill();
 text("MARKET",52,105,76,"#ffffff","bold","Georgia");text("WATCH",350,105,76,"#9e8556","bold","Georgia");
 text(curLabel,198,160,37,"#ffffff","normal","Georgia","center");
 line(54,174,184,174,gold,2);line(455,174,610,174,gold,2);
 text("YEAR-OVER-YEAR SUMMARY",650,116,22,"#9e8556","bold","Georgia");
 text("ALL TRREB AREAS · ALL HOME TYPES",650,145,15,"#ffffff","normal","Georgia");
 if(logo){const maxW=135,maxH=125,scale=Math.min(maxW/logo.width,maxH/logo.height);ctx.drawImage(logo,1010,20,logo.width*scale,logo.height*scale);}
 else{text("DV",1015,125,82,gold,"bold","Georgia");}
 text("DREAM VALLEY",1140,92,27,"#ffffff","normal","Georgia");text("REALTY",1185,124,21,"#ffffff","normal","Georgia");
 // Decorative diagonal edge treatments.
 ctx.fillStyle="#ffffff";ctx.beginPath();ctx.moveTo(0,210);ctx.lineTo(42,255);ctx.lineTo(0,300);ctx.closePath();ctx.fill();
 ctx.fillStyle=gold;ctx.beginPath();ctx.moveTo(1400,760);ctx.lineTo(1400,1050);ctx.lineTo(1160,1050);ctx.closePath();ctx.fill();
 ctx.fillStyle=navy;ctx.beginPath();ctx.moveTo(1400,800);ctx.lineTo(1400,1050);ctx.lineTo(1200,1050);ctx.closePath();ctx.fill();
 ctx.fillStyle=gold;ctx.beginPath();ctx.moveTo(1400,865);ctx.lineTo(1400,1020);ctx.lineTo(1280,1020);ctx.closePath();ctx.fill();
 // chart renderer with paired navy/gold bars and axis labels.
 const chart=(x,y,w,h,key)=>{
  const cur=data.values[key],prev=data.previousValues[key],fmt=formatFor(key),max=Math.max(Number(cur)||0,Number(prev)||0,1)*1.18;
  const base=y+h-34,top=y+8,plotH=base-top;
  line(x+34,base,x+w-8,base,"#9ba5b1",1);
  for(let i=0;i<=4;i++){const yy=base-(plotH*i/4);line(x+34,yy,x+w-8,yy,"#e1e5e9",1);const tick=max*i/4;let label=key==="average_price"?(tick>=1000000?"$"+(tick/1000000).toFixed(2)+"M":"$"+Math.round(tick/1000)+"K"):tick>=1000?Math.round(tick/1000)+"K":Math.round(tick);text(label,x+26,yy+5,13,"#1c2938","normal","Arial","right");}
  const bw=58,bx1=x+Math.max(75,(w-2*bw-45)/2),bx2=bx1+bw+45;
  const bh1=cur==null?0:(Number(cur)/max)*plotH,bh2=prev==null?0:(Number(prev)/max)*plotH;
  if(cur!=null){ctx.fillStyle=navy;ctx.fillRect(bx1,base-bh1,bw,bh1);text(fmt(cur),bx1+bw/2,base-bh1-10,17,navy,"bold","Arial","center");}
  if(prev!=null){ctx.fillStyle=gold;ctx.fillRect(bx2,base-bh2,bw,bh2);text(fmt(prev),bx2+bw/2,base-bh2-10,17,navy,"bold","Arial","center");}
  text(curLabel,bx1+bw/2,base+25,14,navy,"normal","Arial","center");
  text(prevLabel,bx2+bw/2,base+25,14,navy,"normal","Arial","center");
 };
 const yoy=(x,y,w,key)=>{
  const pct=changeFor(key),down=pct!=null&&pct<0,up=pct!=null&&pct>0,color=pct==null?"#778392":down?red:up?green:navy;
  drawRound(x,y,w,104,13,"#fff",color,2);
  text(pct==null?"N/A":(pct>0?"+":"")+pct.toFixed(1)+"%"+(down?" ▼":up?" ▲":""),x+w/2,y+62,39,color,"bold","Georgia","center");
  text("YEAR-OVER-YEAR",x+w/2,y+88,14,navy,"bold","Georgia","center");
 };
 const topCards=[
  {x:38,key:"sales",title:"SOLD",sub:"Units Sold",symbol:"⌂"},
  {x:485,key:"new_listings",title:"NEW LISTINGS",sub:"New Listings",symbol:"⌂"},
  {x:932,key:"active_listings",title:"ACTIVE LISTINGS",sub:"Active Listings",symbol:"▤"}
 ];
 topCards.forEach(card=>{
  drawRound(card.x,210,430,365,22,"#ffffff",gold,2);
  drawCircleIcon(ctx,card.x+78,270,card.symbol);
  text(card.title,card.x+150,258,29,navy,"bold","Georgia");
  text(fmtInt(data.values[card.key]),card.x+150,323,58,navy,"bold","Georgia");
  text(card.sub,card.x+40,365,22,navy,"normal","Georgia");
  yoy(card.x+24,410,162,card.key);
  chart(card.x+190,390,226,160,card.key);
 });
 // Average price feature card.
 drawRound(36,595,650,310,22,navy,null);
 drawCircleIcon(ctx,112,680,"$");
 text("AVERAGE PRICE",180,664,36,"#9e8556","bold","Georgia");
 text(fmtMoney(data.values.average_price),158,742,62,"#ffffff","normal","Georgia");
 text("Average Selling Price",180,786,24,"#ffffff","normal","Georgia");
 text("Year-over-Year",180,825,23,"#ffffff","normal","Georgia");
 yoy(175,838,220,"average_price");
 chart(405,660,255,205,"average_price");
 // Average days on market card.
 drawRound(704,595,660,310,22,"#ffffff",gold,2);
 drawCircleIcon(ctx,780,680,"◷");
 text("AVERAGE DOM",852,664,36,"#9e8556","bold","Georgia");
 text(fmtInt(data.values.days_on_market),850,748,70,navy,"normal","Georgia");
 text("Avg. DOM",850,785,25,navy,"normal","Georgia");
 text("(Listing Days on Market)",850,815,20,navy,"normal","Georgia");
 text("Year-over-Year",850,854,22,navy,"normal","Georgia");
 yoy(850,866,205,"days_on_market");
 chart(1070,650,270,225,"days_on_market");
 // Source strip.
 drawRound(430,920,540,42,20,"#fff8e8",gold,1);
 text("SOURCE: TRREB MARKET WATCH · "+curLabel.toUpperCase(),700,947,17,navy,"bold","Georgia","center");
 // Footer with agent portrait and contact details.
 ctx.fillStyle=navy;ctx.fillRect(0,950,W,170);ctx.fillStyle=gold;ctx.fillRect(0,948,W,4);
 ctx.beginPath();ctx.arc(132,1019,82,0,Math.PI*2);ctx.fillStyle="#ffffff";ctx.fill();ctx.lineWidth=5;ctx.strokeStyle=gold;ctx.stroke();
 if(headshot){ctx.save();ctx.beginPath();ctx.arc(132,1019,74,0,Math.PI*2);ctx.clip();const scale=Math.max(148/headshot.width,148/headshot.height);const sw=148/scale,sh=148/scale;ctx.drawImage(headshot,(headshot.width-sw)/2,(headshot.height-sh)/2,sw,sh,58,926,148,148);ctx.restore();}
 else{text((agent.name||"Agent").split(/\s+/).map(x=>x[0]).slice(0,2).join("").toUpperCase(),132,1031,40,navy,"bold","Arial","center");}
 text(agent.name||"Agent",252,1000,39,"#9e8556","normal","Georgia");
 text(agent.title||"REALTOR®",252,1032,20,"#ffffff","normal","Georgia");
 text(agent.phone||"",320,1070,19,"#ffffff","normal","Arial");
 text(agent.email||"",650,1070,19,"#ffffff","normal","Arial");
 text("dreamvalleyrealty.ca",1040,1070,19,"#ffffff","normal","Arial");
 text("G U I D I N G   Y O U   H O M E ,   E V E R Y   S T E P   O F   T H E   W A Y .",700,1110,13,"#9e8556","normal","Georgia","center");
}
export default function MarketWatchGraphic({agentId,user,adminMode=false}){
 const canvasRef=useRef(null);
 const [allRows,setAllRows]=useState([]),[publishedIds,setPublishedIds]=useState([]),[agent,setAgent]=useState(null),[headshotUrl,setHeadshotUrl]=useState(""),[selectedId,setSelectedId]=useState(""),[loading,setLoading]=useState(true),[error,setError]=useState(""),[notice,setNotice]=useState(""),[editingMetrics,setEditingMetrics]=useState(false),[metricDraft,setMetricDraft]=useState({}),[savingMetrics,setSavingMetrics]=useState(false);
 const load=useCallback(async()=>{
  if(!supabase){setError("Database connection is not configured.");setLoading(false);return;}
  setLoading(true);setError("");
  try{
   let reportQuery=supabase.from("dv_property_market_reports").select("id,report_period,status").neq("report_period","2026-03-01");
   if(!adminMode)reportQuery=reportQuery.eq("status","APPROVED");\n   const {data:publishedReports,error:publishedError}=await reportQuery;
   if(publishedError)throw publishedError;
   const visibleIds=(publishedReports||[]).map(r=>r.id);
   setPublishedIds(visibleIds);
   const pageSize=500;
   const fetchedRows=[];
   for(let offset=0;;offset+=pageSize){
    let rowQuery=supabase.from("dv_property_market_stat_rows").select("*").order("report_period",{ascending:false}).order("source_page",{ascending:true});\n    if(!adminMode)rowQuery=rowQuery.eq("review_status","APPROVED");\n    const {data:page,error:rowsError}=await rowQuery.range(offset,offset+pageSize-1);
    if(rowsError)throw rowsError;
    fetchedRows.push(...(page||[]));
    if(!page||page.length<pageSize)break;
   }
   const safeRows=fetchedRows.filter(r=>String(r.report_period).slice(0,7)!=="2026-03");
   setAllRows(safeRows);
   const grouped=new Map();
   for(const row of safeRows){const key=row.market_report_id;if(!grouped.has(key))grouped.set(key,{id:key,report_period:row.report_period,count:0});grouped.get(key).count++;}
   const choices=[...grouped.values()].sort((a,b)=>b.report_period.localeCompare(a.report_period)||b.count-a.count);
   const bestByMonth=new Map();for(const item of choices)if(!bestByMonth.has(item.report_period))bestByMonth.set(item.report_period,item);
   const clean=[...bestByMonth.values()];
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
 },[agentId,user?.email,adminMode]);
 useEffect(()=>{load();},[load]);
 const reports=useMemo(()=>{const grouped=new Map();for(const row of allRows){if(!publishedIds.includes(row.market_report_id))continue;const key=row.market_report_id;if(!grouped.has(key))grouped.set(key,{id:key,report_period:row.report_period,count:0});grouped.get(key).count++;}const choices=[...grouped.values()].sort((a,b)=>b.report_period.localeCompare(a.report_period)||b.count-a.count);const byMonth=new Map();for(const item of choices)if(!byMonth.has(item.report_period))byMonth.set(item.report_period,item);return [...byMonth.values()];},[allRows,publishedIds]);
 const selected=reports.find(r=>r.id===selectedId)||null;
 const comparison=useMemo(()=>{if(!selected)return null;const target=new Date(selected.report_period+"T00:00:00");target.setFullYear(target.getFullYear()-1);const key=target.toISOString().slice(0,10);const candidates=allRows.filter(r=>r.report_period===key&&r.geography_level==="GTA"&&r.property_type==="ALL"&&(/all gta|all trreb areas|greater toronto area/i.test(r.geography_name||"")));const prior=candidates.find(r=>r.metric_values?.snlr!=null&&r.metric_values?.months_inventory!=null)||candidates[0];return prior?{id:prior.market_report_id,report_period:key}:null;},[allRows,selected]);
 // The monthly GTA summary is the row carrying the monthly market indicators (SNLR and months inventory).
 // YTD and property-type rows can share the same geography label, so do not select them for YoY.
 const findAllGtaRow=list=>{
  const candidates=list.filter(r=>r.property_type==="ALL"&&r.geography_level==="GTA"&&(/all gta|all trreb areas|greater toronto area/i.test(r.geography_name||"")));
  const monthly=candidates.filter(r=>r.metric_values?.snlr!=null&&r.metric_values?.months_inventory!=null);
  return monthly.sort((a,b)=>(a.source_page||999)-(b.source_page||999))[0]||candidates.sort((a,b)=>(a.source_page||999)-(b.source_page||999))[0]||null;
 };
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
  <section className="panel" style={{background:NAVY,color:WHITE,padding:22,marginBottom:16}}><div style={{color:"#9e8556",fontSize:12,fontWeight:800,letterSpacing:2}}>DREAM VALLEY REALTY</div><h1 style={{margin:"8px 0 4px",fontSize:26}}>Market Watch Graphic</h1><p style={{margin:0,opacity:.85}}>Create a branded market update with your agent contact details.</p></section>
  {error&&<div className="notice" role="alert" style={{marginBottom:12,borderColor:"#d97706"}}><AlertCircle size={16}/>{error}</div>}
  {notice&&<div className="notice" role="status" style={{marginBottom:12}}><CheckCircle2 size={16}/>{notice}</div>}
  <section className="panel" style={{marginBottom:14}}>
   <div className="formgrid"><label>{adminMode?"Market Watch month":"Approved Market Watch month"}<select value={selectedId} onChange={e=>{setSelectedId(e.target.value);setNotice("");}}><option value="">Select a report</option>{reports.map(r=><option key={r.id} value={r.id}>{monthLabel(r.report_period)}</option>)}</select></label><label>Agent profile<input value={agent?.name||[agent?.first_name,agent?.last_name].filter(Boolean).join(" ")||"Loading…"} readOnly/></label></div>
   <div className="actions" style={{marginTop:14}}><button type="button" className="secondary" onClick={load} ><RefreshCw size={15}/> Refresh reports</button><button type="button" className="primary" onClick={download} disabled={!canRender}><Download size={16}/> Download PNG</button></div>
   {!selected&&<p className="muted" style={{marginBottom:0}}>No approved Market Watch reports are currently available.</p>}
   {selected&&!currentRow&&<div className="notice" style={{marginTop:12}}>This report does not contain an All GTA / All TRREB Areas, All Home Types summary row. The graphic cannot be generated from incomplete data.</div>}
   {selected&&currentRow&&!comparison&&<p className="muted" style={{marginBottom:0}}>The matching month from the previous year is not available. Year-over-year comparisons will display as unavailable.</p>}
  </section>
  {adminMode&&selected&&currentRow&&<section className="panel" style={{marginBottom:14}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap"}}><div><h3 style={{margin:"0 0 4px"}}>Monthly GTA summary figures</h3><p className="muted" style={{margin:0}}>Edit the saved monthly summary values. Year-over-year percentages are calculated automatically.</p></div><button type="button" className="secondary" onClick={()=>{setMetricDraft({sales:readMetric(currentRow,"sales")??"",new_listings:readMetric(currentRow,"new_listings")??"",active_listings:readMetric(currentRow,"active_listings")??"",average_price:readMetric(currentRow,"average_price")??"",days_on_market:readMetric(currentRow,"days_on_market")??""});setEditingMetrics(v=>!v);}}>{editingMetrics?"Close editor":"Edit monthly figures"}</button></div>
   {editingMetrics&&<div className="formgrid" style={{marginTop:14}}>
    {[[ "sales","Sold" ],[ "new_listings","New listings" ],[ "active_listings","Active listings" ],[ "average_price","Average selling price" ],[ "days_on_market","Average DOM" ]].map(([key,label])=><label key={key}>{label}<input type="number" min="0" step={key==="average_price"?"1":"1"} value={metricDraft[key]??""} onChange={e=>setMetricDraft(v=>({...v,[key]:e.target.value}))}/></label>)}
    <div className="actions" style={{alignItems:"end"}}><button type="button" className="primary" disabled={savingMetrics} onClick={async()=>{setSavingMetrics(true);setError("");setNotice("");try{const next={...(currentRow.metric_values||{})};for(const key of Object.keys(metricDraft)){const raw=metricDraft[key];if(raw===""||!Number.isFinite(Number(raw))||Number(raw)<0)throw new Error("Enter a valid non-negative value for every figure.");next[key]=Number(raw);}const {data,error}=await supabase.from("dv_property_market_stat_rows").update({metric_values:next}).eq("id",currentRow.id).select("id").maybeSingle();if(error)throw error;if(!data)throw new Error("The database did not confirm the statistics update. Check your management permissions.");setAllRows(prev=>prev.map(row=>row.id===currentRow.id?{...row,metric_values:next}:row));setEditingMetrics(false);setNotice("Monthly GTA summary figures saved.");}catch(e){setError(e.message||"Could not save monthly figures.");}finally{setSavingMetrics(false);}}}>Save figures</button></div>
   </div>}
  </section>}
  <section className="panel"><div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:12,flexWrap:"wrap",marginBottom:12}}><div><h2 style={{margin:0}}>Graphic Preview</h2><p className="muted" style={{margin:"4px 0 0"}}>1400 × 1120 px · PNG format</p></div><ImageIcon size={22} color={GOLD}/></div>
   {canRender?<div style={{overflowX:"auto",background:"#e9edf0",padding:10,borderRadius:10}}><canvas ref={canvasRef} style={{display:"block",width:"100%",height:"auto",maxWidth:1100,margin:"0 auto",background:"#e9edf0"}}/></div>:<div className="notice">Select an approved report with complete GTA summary figures to preview the graphic.</div>}
  </section>
 </div>;
}
