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
 const W=1402,H=1122;
 canvas.width=W;canvas.height=H;
 const ctx=canvas.getContext("2d");if(!ctx)return;
 const navy="#0f2141",gold="#9e8556",white="#ffffff",red="#e12626",green="#176b3a",ink="#10233d",muted="#68788a";
 const curLabel=monthLabel(data.report.report_period),prevLabel=data.previous?monthLabel(data.previous.report_period):"Prior year";
 const chartCurLabel=data.report.report_period?new Date(data.report.report_period+"T00:00:00").toLocaleDateString("en-CA",{month:"long",year:"numeric"}):curLabel;
 const chartPrevLabel=data.previous?.report_period?new Date(data.previous.report_period+"T00:00:00").toLocaleDateString("en-CA",{month:"long",year:"numeric"}):"Prior year";
 const compactCurLabel=data.report.report_period?new Date(data.report.report_period+"T00:00:00").toLocaleDateString("en-CA",{month:"short",year:"2-digit"}):"Current";
 const compactPrevLabel=data.previous?.report_period?new Date(data.previous.report_period+"T00:00:00").toLocaleDateString("en-CA",{month:"short",year:"2-digit"}):"Prior";
 const pct=k=>percent(data.values[k],data.previousValues[k]);
 const number=v=>fmtInt(v);
 const money=v=>fmtMoney(v);
 const rounded=(x,y,w,h,r,fill,stroke=gold,lw=2,shadow=true)=>{
  ctx.save();if(shadow){ctx.shadowColor="rgba(0,0,0,.17)";ctx.shadowBlur=13;ctx.shadowOffsetY=5;}
  ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fillStyle=fill;ctx.fill();ctx.restore();
  if(stroke){ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}
 };
 const text=(v,x,y,size,color=ink,weight="normal",font="Georgia",align="left")=>{
  ctx.save();ctx.font=weight+" "+size+"px "+font;ctx.fillStyle=color;ctx.textAlign=align;ctx.textBaseline="alphabetic";ctx.fillText(String(v??""),x,y);ctx.restore();
 };
 const line=(x1,y1,x2,y2,color=gold,width=2)=>{
  ctx.beginPath();ctx.moveTo(x1,y1);ctx.lineTo(x2,y2);ctx.strokeStyle=color;ctx.lineWidth=width;ctx.stroke();
 };
 const circle=(x,y,r,fill,stroke=gold,lw=3)=>{
  ctx.beginPath();ctx.arc(x,y,r,0,Math.PI*2);ctx.fillStyle=fill;ctx.fill();if(stroke){ctx.lineWidth=lw;ctx.strokeStyle=stroke;ctx.stroke();}
 };
 const icon=(kind,cx,cy,r=42)=>{
  circle(cx,cy,r,navy,gold,3);ctx.save();ctx.strokeStyle=gold;ctx.fillStyle=gold;ctx.lineWidth=4;ctx.lineCap="round";ctx.lineJoin="round";
  if(kind==="key"){
   ctx.beginPath();ctx.arc(cx+5,cy-10,13,0,Math.PI*2);ctx.stroke();line(cx-4,cy-1,cx-23,cy+20,gold,6);line(cx-17,cy+13,cx-10,cy+20,gold,5);line(cx-10,cy+6,cx-3,cy+13,gold,5);
  }else if(kind==="house"){
   ctx.beginPath();ctx.moveTo(cx-24,cy-5);ctx.lineTo(cx,cy-27);ctx.lineTo(cx+25,cy-5);ctx.moveTo(cx-18,cy-9);ctx.lineTo(cx-18,cy+23);ctx.lineTo(cx+18,cy+23);ctx.lineTo(cx+18,cy-9);ctx.stroke();ctx.strokeRect(cx-7,cy+5,14,18);line(cx+10,cy-20,cx+10,cy-31,gold,4);
  }else if(kind==="list"){
   ctx.strokeRect(cx-18,cy-24,36,48);for(let yy=cy-12;yy<=cy+13;yy+=13){circle(cx-9,yy,2.3,gold,null,0);line(cx-2,yy,cx+12,yy,gold,3);}
  }else if(kind==="dollar"){text("$",cx,cy+17,43,gold,"bold","Georgia","center");}
  else if(kind==="calendar"){
   ctx.strokeRect(cx-22,cy-17,44,39);line(cx-22,cy-6,cx+22,cy-6,gold,3);line(cx-11,cy-25,cx-11,cy-12,gold,4);line(cx+11,cy-25,cx+11,cy-12,gold,4);for(let xx of [-10,2,13])for(let yy of [2,12])circle(cx+xx,cy+yy,2,gold,null,0);
  }
  ctx.restore();
 };
 const drawYoy=(x,y,w,h,key)=>{
  const p=pct(key),color=p==null?muted:p<0?red:p>0?green:navy;
  rounded(x,y,w,h,12,white,color,2,false);
  const label=p==null?"N/A":(p>0?"+":"")+p.toFixed(1)+"%";
  text(label,x+w/2,y+h*.58,p==null?38:Math.min(45,h*.48),color,"bold","Georgia","center");
  if(p!=null&&p!==0){
   const ax=x+w/2+(label.length*11);
   text(p<0?"▼":"▲",Math.min(x+w-20,ax),y+h*.58,27,color,"bold","Arial","center");
  }
  text("YEAR-OVER-YEAR",x+w/2,y+h-13,13,ink,"bold","Georgia","center");
 };
 const drawChart=(x,y,w,h,key,compact=false)=>{
  const cur=data.values[key],prev=data.previousValues[key],isPrice=key==="average_price";
  const vals=[Number(cur)||0,Number(prev)||0],maxRaw=Math.max(...vals,1);
  const max=isPrice?Math.ceil(maxRaw/250000)*250000:key==="days_on_market"?Math.ceil(maxRaw/10)*10:Math.ceil(maxRaw/2000)*2000;
  const left=compact?28:(isPrice?43:54),right=compact?7:8,top=compact?18:12,bottom=compact?43:48;
  const plotX=x+left,plotY=y+top,plotW=w-left-right,base=y+h-bottom,plotH=base-plotY;
  line(plotX,base,plotX+plotW,base,"#b8c0c9",1);
  for(let i=0;i<=4;i++){
   const yy=base-plotH*i/4;line(plotX,yy,plotX+plotW,yy,"#e6e9ed",1);
   const v=max*i/4;
   let tick=isPrice?(v===0?"$0":v>=1000000?"$"+(v/1000000).toFixed(v%1000000===0?0:2)+"M":"$"+Math.round(v/1000)+"K"):number(v);
   if(!isPrice&&v>=1000)tick=Math.round(v/1000)+"K";
   if(key==="days_on_market")tick=String(Math.round(v));
   text(tick,plotX-7,yy+4,compact?10:13,ink,"normal","Arial","right");
  }
  const bw=compact?34:(isPrice?54:58);
  const center1=plotX+plotW*(compact?0.27:0.25),center2=plotX+plotW*(compact?0.73:0.75);
  const bx1=center1-bw/2,bx2=center2-bw/2;
  const barH=v=>v==null?0:Math.max(2,(Number(v)/max)*plotH);
  const h1=barH(cur),h2=barH(prev);
  const valueLabel=v=>isPrice?money(v):number(v);
  if(cur!=null){if(isPrice){ctx.fillStyle="#f5f0e5";ctx.fillRect(bx1,base-h1,bw,h1);ctx.strokeStyle="#ffffff";ctx.lineWidth=2;ctx.strokeRect(bx1,base-h1,bw,h1);}else{ctx.fillStyle=navy;ctx.fillRect(bx1,base-h1,bw,h1);}text(valueLabel(cur),bx1+bw/2,base-h1-7,compact?10:isPrice?11:14,ink,"bold","Arial","center");}
  if(prev!=null){ctx.fillStyle=gold;ctx.fillRect(bx2,base-h2,bw,h2);text(valueLabel(prev),bx2+bw/2,base-h2-7,compact?10:isPrice?10:14,ink,"bold","Arial","center");}
  const labelSize=compact?9:10;
  text(compact?compactCurLabel:chartCurLabel,bx1+bw/2,base+(compact?17:21),labelSize,ink,"normal","Arial","center");
  text(compact?compactPrevLabel:chartPrevLabel,bx2+bw/2,base+(compact?17:21),labelSize,ink,"normal","Arial","center");
 }; // Background and header.
 const bg=ctx.createLinearGradient(0,0,W,H);bg.addColorStop(0,"#fbfaf7");bg.addColorStop(1,"#e9edf0");ctx.fillStyle=bg;ctx.fillRect(0,0,W,H);
 ctx.fillStyle="#ffffff";ctx.beginPath();ctx.moveTo(0,205);ctx.lineTo(34,242);ctx.lineTo(34,734);ctx.lineTo(0,748);ctx.closePath();ctx.fill();
 ctx.beginPath();ctx.moveTo(W,205);ctx.lineTo(W-34,242);ctx.lineTo(W-34,734);ctx.lineTo(W,748);ctx.closePath();ctx.fill();
 ctx.fillStyle=navy;ctx.fillRect(0,0,W,198);
 // Toronto skyline and CN Tower, in the same header position as the master.
 const buildings=[[846,137,20,61],[870,112,22,86],[897,143,16,55],[918,102,22,96],[944,126,18,72],[966,78,24,120],[995,117,19,81],[1018,94,25,104],[1048,132,18,66],[1070,108,25,90],[1101,137,18,61],[1122,116,22,82],[1148,143,20,55]];
 ctx.fillStyle="#102b46";buildings.forEach(([bx,by,bw,bh])=>{ctx.fillRect(bx,by,bw,bh);ctx.fillStyle="#2d4962";for(let yy=by+9;yy<by+bh-5;yy+=13)for(let xx=bx+5;xx<bx+bw-3;xx+=8)ctx.fillRect(xx,yy,3,4);ctx.fillStyle="#102b46";});
 line(897,49,897,154,"#53677a",3);line(889,79,905,79,"#53677a",3);line(891,65,903,65,"#53677a",2);
 ctx.beginPath();ctx.moveTo(897,49);ctx.lineTo(892,67);ctx.lineTo(902,67);ctx.closePath();ctx.fillStyle="#53677a";ctx.fill();
 ctx.save();ctx.font="normal 76px Georgia";const marketWidth=ctx.measureText("MARKET").width;ctx.restore();
 text("MARKET",53,121,72,white,"normal","Georgia");text("WATCH",53+marketWidth+14,121,72,gold,"bold","Georgia");
 text(curLabel,230,166,34,white,"normal","Georgia","center");line(54,154,184,154,gold,2);line(455,154,612,154,gold,2);
 text("YEAR-OVER-YEAR SUMMARY",735,132,21,gold,"bold","Georgia");text("ALL TRREB AREAS · ALL HOME TYPES",735,160,14,white,"normal","Georgia");
 if(logo){const scale=Math.min(112/logo.width,118/logo.height);ctx.drawImage(logo,1024,22,logo.width*scale,logo.height*scale);}
 text("DREAM VALLEY",1140,96,27,white,"normal","Georgia");text("REALTY",1193,126,20,white,"normal","Georgia");
 // Master card layout: three top cards and two lower cards.
 const top=[
  {x:39,w:428,key:"sales",title:"SOLD",sub:"Units Sold",icon:"key",yoyX:61,chartX:224},
  {x:474,w:406,key:"new_listings",title:"NEW LISTINGS",sub:"New Listings",icon:"house",yoyX:497,chartX:661},
  {x:887,w:453,key:"active_listings",title:"ACTIVE LISTINGS",sub:"Active Listings",icon:"list",yoyX:914,chartX:1077}
 ];
 top.forEach(c=>{
  rounded(c.x,198,c.w,368,21,white,gold,2,true);
  icon(c.icon,c.x+62,255,42);
  text(c.title,c.x+132,250,29,ink,"bold","Georgia");
  text(number(data.values[c.key]),c.x+124,312,58,ink,"bold","Georgia");
  text(c.sub,c.x+38,344,21,ink,"normal","Georgia");
  drawYoy(c.yoyX,406,c.chartX-c.yoyX-12,100,c.key);
  drawChart(c.chartX,327,c.x+c.w-c.chartX-12,207,c.key,true);
 });
 // Average price panel.
 rounded(36,578,651,321,22,navy,null,0,true);
 icon("dollar",116,658,43);
 text("AVERAGE PRICE",178,637,36,gold,"bold","Georgia");
 text(money(data.values.average_price),157,695,58,white,"normal","Georgia");
 text("Average Selling Price",170,739,23,white,"normal","Georgia");
 text("Year-over-Year",198,772,22,white,"normal","Georgia");
 drawYoy(170,786,220,70,"average_price");
 drawChart(405,630,270,250,"average_price",false);
 // Average DOM panel.
 rounded(697,578,643,321,22,white,gold,2,true);
 icon("calendar",765,658,43);
 text("AVERAGE DOM",846,637,37,gold,"bold","Georgia");
 text(number(data.values.days_on_market),846,704,70,ink,"normal","Georgia");
 text("Avg. DOM",846,741,24,ink,"normal","Georgia");
 text("(Listing Days on Market)",846,770,19,ink,"normal","Georgia");
 text("Year-over-Year",801,801,21,ink,"normal","Georgia");
 drawYoy(786,817,168,70,"days_on_market");
 drawChart(1000,630,315,248,"days_on_market",false);
 // Source pill and footer. The footer begins below all cards/charts.
 rounded(437,911,502,31,16,"#fff8e9",gold,1,false);
 text("SOURCE: TRREB MARKET WATCH · "+curLabel.toUpperCase(),688,932,16,ink,"bold","Georgia","center");
 ctx.fillStyle=navy;ctx.fillRect(0,948,W,174);ctx.fillStyle=gold;ctx.fillRect(0,946,W,3);
 // Decorative footer corner.
 ctx.fillStyle="#f5f0e5";ctx.beginPath();ctx.moveTo(1402,949);ctx.lineTo(1402,1122);ctx.lineTo(1220,1122);ctx.closePath();ctx.fill();
 ctx.fillStyle=gold;ctx.beginPath();ctx.moveTo(1402,979);ctx.lineTo(1402,1122);ctx.lineTo(1280,1122);ctx.closePath();ctx.fill();
 ctx.fillStyle=navy;ctx.beginPath();ctx.moveTo(1402,1003);ctx.lineTo(1402,1122);ctx.lineTo(1310,1122);ctx.closePath();ctx.fill();
 // Agent portrait with a fixed circular crop.
 circle(141,995,91,white,gold,5);
 if(headshot){ctx.save();ctx.beginPath();ctx.arc(141,995,83,0,Math.PI*2);ctx.clip();const scale=Math.max(166/headshot.width,166/headshot.height),sw=166/scale,sh=166/scale;ctx.drawImage(headshot,(headshot.width-sw)/2,(headshot.height-sh)/2,sw,sh,58,912,166,166);ctx.restore();}
 else{text((agent.name||"Agent").split(/\s+/).map(v=>v[0]).slice(0,2).join("").toUpperCase(),141,1008,40,navy,"bold","Arial","center");}
 const agentName=agent.name||"Agent";
 text(agentName,252,993,38,gold,"normal","Georgia");
 text(agent.title||"REALTOR®",252,1024,20,white,"normal","Georgia");
 // Contact icons and details aligned on one baseline.
 text("☎",252,1061,23,gold,"normal","Arial");text(agent.phone||"",286,1061,20,white,"normal","Arial");
 text("✉",610,1061,25,gold,"normal","Arial");text(agent.email||"",650,1061,20,white,"normal","Arial");
 text("◎",1014,1061,25,gold,"normal","Arial");text("dreamvalleyrealty.ca",1050,1061,20,white,"normal","Arial");
 text("G U I D I N G   Y O U   H O M E ,   E V E R Y   S T E P   O F   T H E   W A Y .",701,1102,13,gold,"normal","Georgia","center");
}
export default function MarketWatchGraphic({agentId,user,adminMode=false}){
 const canvasRef=useRef(null);
 const [allRows,setAllRows]=useState([]),[publishedIds,setPublishedIds]=useState([]),[agent,setAgent]=useState(null),[headshotUrl,setHeadshotUrl]=useState(""),[selectedId,setSelectedId]=useState(""),[loading,setLoading]=useState(true),[error,setError]=useState(""),[notice,setNotice]=useState(""),[editingMetrics,setEditingMetrics]=useState(false),[metricDraft,setMetricDraft]=useState({}),[savingMetrics,setSavingMetrics]=useState(false),[referenceTestPreview,setReferenceTestPreview]=useState(false);
 const load=useCallback(async()=>{
  if(!supabase){setError("Database connection is not configured.");setLoading(false);return;}
  setLoading(true);setError("");
  try{
   let reportQuery=supabase.from("dv_property_market_reports").select("id,report_period,status").neq("report_period","2026-03-01");
   if(!adminMode)reportQuery=reportQuery.eq("status","APPROVED");
   const {data:publishedReports,error:publishedError}=await reportQuery;
   if(publishedError)throw publishedError;
   const visibleIds=(publishedReports||[]).map(r=>r.id);
   setPublishedIds(visibleIds);
   const pageSize=500;
   const fetchedRows=[];
   for(let offset=0;;offset+=pageSize){
    let rowQuery=supabase.from("dv_property_market_stat_rows").select("*").order("report_period",{ascending:false}).order("source_page",{ascending:true});
    if(!adminMode)rowQuery=rowQuery.eq("review_status","APPROVED");
    const {data:page,error:rowsError}=await rowQuery.range(offset,offset+pageSize-1);
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
 const isSeptember2026=selected?.report_period==="2026-09-01";
 const previewValues=useMemo(()=>referenceTestPreview&&adminMode&&isSeptember2026?{...values,sales:5040,new_listings:16500,active_listings:26131,average_price:1006409,days_on_market:34}:values,[referenceTestPreview,adminMode,isSeptember2026,values]);
 const previewPreviousValues=useMemo(()=>referenceTestPreview&&adminMode&&isSeptember2026?{...previousValues,sales:5540,new_listings:19280,active_listings:28813,average_price:1060036,days_on_market:33}:previousValues,[referenceTestPreview,adminMode,isSeptember2026,previousValues]);
 const canRender=!!selected&&!!currentRow&&Object.values(values).some(v=>v!==null);
 useEffect(()=>{
  let cancelled=false;
  if(!canRender||!agent||!canvasRef.current)return;
  Promise.all([safeImage(headshotUrl),safeImage("/dv-logo.svg")]).then(([head,logo])=>{if(cancelled)return;drawGraphic(canvasRef.current,{report:selected,previous:comparison,values:previewValues,previousValues:previewPreviousValues}, {name:agent.name||[agent.first_name,agent.last_name].filter(Boolean).join(" "),title:"REALTOR®",phone:agent.cell_phone||"",email:agent.email||""},head,logo);});
  return()=>{cancelled=true;};
 },[canRender,selected?.id,comparison?.id,JSON.stringify(previewValues),JSON.stringify(previewPreviousValues),agent,headshotUrl]);
 const download=()=>{const canvas=canvasRef.current;if(!canvas)return;canvas.toBlob(blob=>{if(!blob){setError("The image could not be created. Please try again.");return;}const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download="Dream-Valley-Market-Watch-"+String(selected.report_period).slice(0,7)+"-"+(agent?.name||"Agent").replace(/[^a-z0-9]+/gi,"-")+".png";a.click();URL.revokeObjectURL(url);setNotice("Your Market Watch graphic has been downloaded.");},"image/png");};
 if(loading)return <section className="panel"><p>Loading your Market Watch graphic workspace…</p></section>;
 return <div className="market-watch-graphic">
  <section className="panel" style={{background:NAVY,color:WHITE,padding:22,marginBottom:16}}><div style={{color:"#9e8556",fontSize:12,fontWeight:800,letterSpacing:2}}>DREAM VALLEY REALTY</div><h1 style={{margin:"8px 0 4px",fontSize:26}}>Market Watch Graphic</h1><p style={{margin:0,opacity:.85}}>Create a branded market update with your agent contact details.</p></section>
  {error&&<div className="notice" role="alert" style={{marginBottom:12,borderColor:"#d97706"}}><AlertCircle size={16}/>{error}</div>}
  {notice&&<div className="notice" role="status" style={{marginBottom:12}}><CheckCircle2 size={16}/>{notice}</div>}
  <section className="panel" style={{marginBottom:14}}>
   <div className="formgrid"><label>{adminMode?"Market Watch month":"Approved Market Watch month"}<select value={selectedId} onChange={e=>{setSelectedId(e.target.value);setNotice("");}}><option value="">Select a report</option>{reports.map(r=><option key={r.id} value={r.id}>{monthLabel(r.report_period)}</option>)}</select></label><label>Agent profile<input value={agent?.name||[agent?.first_name,agent?.last_name].filter(Boolean).join(" ")||"Loading…"} readOnly/></label></div>
   <div className="actions" style={{marginTop:14}}><button type="button" className="secondary" onClick={load} ><RefreshCw size={15}/> Refresh reports</button><button type="button" className="primary" onClick={download} disabled={!canRender}><Download size={16}/> Download PNG</button></div>
   {adminMode&&isSeptember2026&&<div className="actions" style={{marginTop:10}}>
    <button type="button" className={referenceTestPreview?"primary":"secondary"} onClick={()=>setReferenceTestPreview(v=>!v)}>{referenceTestPreview?"Reference test figures enabled":"Preview reference test figures"}</button>
    <span className="muted">Admin preview only. This does not update saved statistics or published reports.</span>
   </div>}
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
   {canRender?<div style={{overflowX:"auto",background:"#e9edf0",padding:10,borderRadius:10}}>
    {adminMode&&referenceTestPreview&&<p className="muted" style={{textAlign:"center",margin:"0 0 8px"}}>Reference test figures preview — values are not saved to the database.</p>}<canvas ref={canvasRef} style={{display:"block",width:"100%",height:"auto",maxWidth:1100,margin:"0 auto",background:"#e9edf0"}}/></div>:<div className="notice">Select an approved report with complete GTA summary figures to preview the graphic.</div>}
  </section>
 </div>;
}
