import * as pdfjsLib from "pdfjs-dist/legacy/build/pdf.mjs";
import pdfWorker from "pdfjs-dist/legacy/build/pdf.worker.mjs?url";
pdfjsLib.GlobalWorkerOptions.workerSrc=pdfWorker;

const sanitize=value=>Array.from(String(value??"")).filter(ch=>{const cp=ch.codePointAt(0);return cp!==0&&!(cp>=0xD800&&cp<=0xDFFF)&&!(cp<32&&cp!==9&&cp!==10&&cp!==13);}).join("");
const numberPattern=/\$?[\d,]+(?:\.\d+)?%?/g;
const MONTHS="January February March April May June July August September October November December".split(" ");

function parseRows(pageLines,reportPeriod){
 const rows=[];
 const propertyTypeFrom=text=>{
  const m=text.match(/(All Home types|Detached|Semi[- ]Detached|Condo Townhouse|Townhouse|Condo Apartment|Condo Apt|Att\/Row\/Twnhouse|Freehold Townhouse),?\s+[A-Za-z]+,?\s+(?:Year-to-Date\s+)?20\d{2}/i);
  const v=m?.[1]||"";
  if(/all home types/i.test(v))return "ALL";
  if(/semi/i.test(v))return "Semi-Detached";
  if(/detached/i.test(v))return "Detached";
  if(/condo townhouse/i.test(v))return "Condo Townhouse";
  if(/att\/row|freehold townhouse/i.test(v))return "Freehold Townhouse";
  if(/condo apartment|condo apt/i.test(v))return "Condo Apartment";
  if(/townhouse/i.test(v))return "Townhouse";
  return "ALL";
 };
 for(const page of pageLines){
  const pageText=page.lines.join(" ");
  if(!/Dollar\s+Volume/i.test(pageText)||!/Average\s+Price/i.test(pageText)||!/Median\s+Price/i.test(pageText)||!/New\s+Listings/i.test(pageText))continue;
  const propertyType=propertyTypeFrom(pageText);
  for(const line of page.lines){
   const match=line.match(/^\s*(.+?)\s{2,}(?=\$?[\d,])/);
   if(!match)continue;
   const geography=match[1].replace(/\s+/g," ").trim().replace(/^(?:area|municipality)derived\s+/i,"");
   if(!geography||/^(sales|share of total|average price|area derived|areaderived)$/i.test(geography))continue;
   const tokens=line.slice(match[0].length).match(numberPattern)||[];
   if(tokens.length!==11&&tokens.length!==8)continue;
   const n=tokens.map(v=>Number(v.replace(/[$,%]/g,"").replace(/,/g,"")));
   if(n.some(v=>!Number.isFinite(v)))continue;
   const full=tokens.length===11;
   const gta=/^All TRREB Areas$/i.test(geography);
   const community=/^Toronto\s+[WCE]\d{2}$/i.test(geography);
   const region=/^(Halton|Peel|York|Durham|Toronto) Region$/i.test(geography);
   const metrics=full?{sales:n[0],dollar_volume:n[1],average_price:n[2],median_price:n[3],new_listings:n[4],snlr:n[5],active_listings:n[6],months_inventory:n[7],sale_to_list_ratio:n[8],days_on_market:n[9],property_days_on_market:n[10]}:{sales:n[0],dollar_volume:n[1],average_price:n[2],median_price:n[3],new_listings:n[4],active_listings:n[5],sale_to_list_ratio:n[6],days_on_market:n[7]};
   rows.push({report_period:reportPeriod,geography_level:gta?"GTA":community?"COMMUNITY":region?"REGION":"MUNICIPALITY",geography_name:gta?"All GTA":geography,geography_parent:community?"City of Toronto":null,property_type:propertyType,metric_values:metrics,source_page:page.page,source_table:propertyType,extraction_method:full?"PDF_TEXT_LAYOUT_11_METRICS":"PDF_TEXT_LAYOUT_8_METRICS",review_status:"PENDING"});
  }
 }
 const unique=new Map();
 for(const row of rows){const key=[row.report_period,row.geography_level,row.geography_name,row.property_type].join("|");if(!unique.has(key))unique.set(key,row);}
 return [...unique.values()];
}
export async function extractMarketWatchPdf(file,expectedPeriod){
 if(file.size>25*1024*1024)throw new Error("PDF exceeds the 25 MB upload limit.");
 const bytes=new Uint8Array(await file.arrayBuffer());
 const pdf=await pdfjsLib.getDocument({data:bytes}).promise;
 const pageLines=[];let fullText="";
 for(let i=1;i<=pdf.numPages;i++){
  const page=await pdf.getPage(i),content=await page.getTextContent(),items=[];
  for(const item of content.items){
   if(!item.str?.trim())continue;
   items.push({y:item.transform?.[5]||0,x:item.transform?.[4]||0,text:sanitize(item.str)});
  }
  // Cluster text items on nearby visual baselines; PDF table cells often differ slightly in Y.
  items.sort((a,b)=>b.y-a.y||a.x-b.x);
  const clusters=[];
  for(const item of items){
   let cluster=clusters.find(row=>Math.abs(row.y-item.y)<=8);
   if(!cluster){cluster={y:item.y,items:[]};clusters.push(cluster);}
   cluster.items.push(item);
  }
  const lines=clusters.sort((a,b)=>b.y-a.y).map(row=>row.items.sort((a,b)=>a.x-b.x).map(x=>x.text).join("  "));
  pageLines.push({page:i,lines});fullText+=lines.join("\n")+"\n";
 }
 const cover=pageLines.slice(0,2).flatMap(p=>p.lines);
 const monthLine=cover.map(x=>x.trim()).find(x=>new RegExp("^("+MONTHS.join("|")+")\\s+20\\d{2}$","i").test(x));
 const fileMatch=file.name.match(/^mw(\d{2})(0[1-9]|1[0-2])(?:\D|$)/i);
 const detected=fileMatch?"20"+fileMatch[1]+"-"+fileMatch[2]+"-01":monthLine?new Date(monthLine+" 1").toISOString().slice(0,7)+"-01":null;
 if(!detected)throw new Error("Could not identify the report month from the PDF cover or filename.");
 if(detected.slice(0,7)!==expectedPeriod.slice(0,7))throw new Error("Report month mismatch. Selected "+expectedPeriod.slice(0,7)+" but PDF indicates "+detected.slice(0,7)+". Correct the report month or upload the matching PDF.");
 const tablePages=pageLines.filter(p=>{const t=p.lines.join(" ");return /Dollar\s+Volume/i.test(t)&&/Average\s+Price/i.test(t)&&/Median\s+Price/i.test(t)&&/New\s+Listings/i.test(t);}).length;
 const candidateRows=pageLines.reduce((sum,p)=>sum+p.lines.filter(line=>/^\s*.+?\s{2,}(?=\$?[\d,])/.test(line)).length,0);
 const rows=parseRows(pageLines,expectedPeriod);
 const coverText=pageLines.slice(0,4).flatMap(p=>p.lines).join(" ");
 const headline=coverText.match(/(\d[\d,]*)\s+(?:Sales|Homes Sold)[\s\S]{0,100}?(\$?\d[\d,]*)/i);
 return {pages:pdf.numPages,text:sanitize(fullText),rows,detectedMonth:detected,summary:{cover_text:coverText,extracted_pages:pdf.numPages,extracted_rows:rows.length,table_pages:tablePages,candidate_rows:candidateRows,headline_match:headline?headline[0]:null}};
}
