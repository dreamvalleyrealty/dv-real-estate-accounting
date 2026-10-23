import React, { useMemo } from "react";
import { calculateCommercialLeaseCommission, COMMISSION_BASES, NET_TREATMENTS, HST_TREATMENTS } from "./lib/commercialLeaseCommission";

const money = n => n == null || !Number.isFinite(Number(n)) ? "—" : new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n));
const inputStyle={width:"100%",boxSizing:"border-box",padding:"7px 8px",border:"1px solid #cbd5e1",borderRadius:6,minWidth:0};
const labelStyle={display:"grid",gap:4,fontSize:12,fontWeight:600,minWidth:0};
const rentDefault=()=>({periodLabel:"Years 1–1",startPeriod:1,endPeriod:1,baseRent:"",additionalRent:"0",escalationType:"NONE",escalationValue:"0"});
const commissionDefault=()=>({periodLabel:"Years 1–1",startPeriod:1,endPeriod:1,base:"BASE_RENT",ratePercent:"",fixedAmount:"",monthsOfRent:"",netTreatment:"GROSS_COMMISSION",netDefinition:"",deductions:"0",netPayableAmount:"",hstTreatment:"ADDED",hstRatePercent:"13",hstExemptionReason:"",paymentTrigger:"LEASE_START",paymentTriggerDescription:"",customFormulaDescription:""});
export default function CommercialLeaseCommissionEditor({value,onChange,readOnly=false}){
 const data=value&&typeof value==="object"?value:{leaseTermMonths:"12",squareFeet:"",rentSchedule:[rentDefault()],commissionSchedule:[commissionDefault()],signedAgreementDocumentId:"",commissionAuthorityConfirmed:false};
 const set=(key,val)=>onChange({...data,[key]:val});
 const setRow=(key,index,patch)=>set(key,data[key].map((r,i)=>i===index?{...r,...patch}:r));
 const result=useMemo(()=>calculateCommercialLeaseCommission(data),[data]);
 const addRow=(key,make)=>set(key,[...(data[key]||[]),make()]);
 const removeRow=(key,index)=>set(key,data[key].filter((_,i)=>i!==index));
 const field=(label,control)=><label style={labelStyle}>{label}{control}</label>;
 const inp=(v,fn,type="text",props={})=><input style={inputStyle} type={type} value={v??""} onChange={e=>fn(e.target.value)} {...props}/>;
 const select=(v,fn,opts)=><select style={inputStyle} value={v||""} onChange={e=>fn(e.target.value)}>{opts.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select>;
 const rowGrid={display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(130px,1fr))",gap:8,alignItems:"end"};
 return <section style={{border:"1px solid #cbd5e1",borderRadius:8,padding:12,marginTop:12,display:"grid",gap:12}}>
  <div><h4 style={{margin:"0 0 4px"}}>Commercial lease commission schedule</h4><div style={{fontSize:12,color:"#475569"}}>Enter the signed agreement's terms. Calculations do not replace review of the agreement.</div></div>
  <div style={rowGrid}>
   {field("Lease term (months)",inp(data.leaseTermMonths,v=>set("leaseTermMonths",v),"number",{min:1,max:1200}))}
   {field("Leased area (sq. ft.)",inp(data.squareFeet,v=>set("squareFeet",v),"number",{min:0,step:"0.01"}))}
  </div>
  <div style={{display:"grid",gap:8,minWidth:0}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:8}}><b>Rent schedule</b>{!readOnly&&<button type="button" onClick={()=>addRow("rentSchedule",rentDefault)} style={{padding:"5px 9px",whiteSpace:"nowrap"}}>＋ Add period</button>}</div>
   <div style={{overflowX:"auto",border:"1px solid #e2e8f0",borderRadius:6}}>
    <table style={{borderCollapse:"collapse",width:"100%",minWidth:900,fontSize:12}}>
     <thead><tr>{["Period","From year","To year","Annual base rent ($)","Annual additional rent ($)","Rent increase","Increase (%) / ($)",""].map((h,i)=><th key={i} style={{textAlign:"left",padding:7,background:"#f8fafc",borderBottom:"1px solid #e2e8f0",whiteSpace:"nowrap"}}>{h}</th>)}</tr></thead>
     <tbody>{(data.rentSchedule||[]).map((r,i)=><tr key={i}>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.periodLabel,v=>setRow("rentSchedule",i,{periodLabel:v}))}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.startPeriod,v=>setRow("rentSchedule",i,{startPeriod:v}),"number",{min:1})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.endPeriod,v=>setRow("rentSchedule",i,{endPeriod:v}),"number",{min:1})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.baseRent,v=>setRow("rentSchedule",i,{baseRent:v}),"number",{min:0,step:"0.01"})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.additionalRent,v=>setRow("rentSchedule",i,{additionalRent:v}),"number",{min:0,step:"0.01"})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{select(r.escalationType,v=>setRow("rentSchedule",i,{escalationType:v}),[{value:"NONE",label:"No increase"},{value:"PERCENT",label:"Percentage"},{value:"FIXED",label:"Fixed amount"},{value:"CARRY_FORWARD",label:"Carry forward"}])}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{r.escalationType!=="NONE"?inp(r.escalationValue,v=>setRow("rentSchedule",i,{escalationValue:v}),"number",{min:0,step:"0.01"}):<span style={{color:"#94a3b8"}}>—</span>}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4",whiteSpace:"nowrap"}}>{!readOnly&&<button type="button" title="Remove period" onClick={()=>removeRow("rentSchedule",i)} disabled={data.rentSchedule.length<=1} style={{padding:"5px 8px"}}>×</button>}</td>
     </tr>)}</tbody>
    </table>
   </div>
  </div>
  <div style={{display:"grid",gap:8,minWidth:0}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:8}}><b>Commission rates by lease period</b>{!readOnly&&<button type="button" onClick={()=>addRow("commissionSchedule",commissionDefault)} style={{padding:"5px 9px",whiteSpace:"nowrap"}}>＋ Add period</button>}</div>
   <div style={{overflowX:"auto",border:"1px solid #e2e8f0",borderRadius:6}}>
    <table style={{borderCollapse:"collapse",width:"100%",minWidth:1400,fontSize:12}}>
     <thead><tr>{["Period","From year","To year","Calculation method","Rate (%)","Fixed / sq. ft. fee ($)","Months rent","NET treatment","Deductions / agreed net ($)","HST treatment","HST rate (%)","Payment trigger",""].map((h,i)=><th key={i} style={{textAlign:"left",padding:7,background:"#f8fafc",borderBottom:"1px solid #e2e8f0",whiteSpace:"nowrap"}}>{h}</th>)}</tr></thead>
     <tbody>{(data.commissionSchedule||[]).map((r,i)=><tr key={i}>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.periodLabel,v=>setRow("commissionSchedule",i,{periodLabel:v}))}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.startPeriod,v=>setRow("commissionSchedule",i,{startPeriod:v}),"number",{min:1})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{inp(r.endPeriod,v=>setRow("commissionSchedule",i,{endPeriod:v}),"number",{min:1})}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{select(r.base,v=>setRow("commissionSchedule",i,{base:v}),COMMISSION_BASES)}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{["BASE_RENT","GROSS_RENT","BASE_AND_ADDITIONAL_RENT"].includes(r.base)?inp(r.ratePercent,v=>setRow("commissionSchedule",i,{ratePercent:v}),"number",{min:0,max:100,step:"0.01"}):<span>—</span>}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{["FIXED_AMOUNT","PER_SQUARE_FOOT"].includes(r.base)?inp(r.fixedAmount,v=>setRow("commissionSchedule",i,{fixedAmount:v}),"number",{min:0,step:"0.01"}):<span>—</span>}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{r.base==="MONTHS_OF_RENT"?inp(r.monthsOfRent,v=>setRow("commissionSchedule",i,{monthsOfRent:v}),"number",{min:0,step:"0.01"}):<span>—</span>}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{select(r.netTreatment,v=>setRow("commissionSchedule",i,{netTreatment:v}),NET_TREATMENTS)}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{r.netTreatment==="LESS_SPECIFIED_DEDUCTIONS"?inp(r.deductions,v=>setRow("commissionSchedule",i,{deductions:v}),"number",{min:0,step:"0.01"}):r.netTreatment==="NET_PAYABLE_TO_COOPERATING_BROKERAGE"?inp(r.netPayableAmount,v=>setRow("commissionSchedule",i,{netPayableAmount:v}),"number",{min:0,step:"0.01"}):r.netTreatment==="OTHER_DEFINED"?inp(r.netDefinition,v=>setRow("commissionSchedule",i,{netDefinition:v})):<span>—</span>}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{select(r.hstTreatment,v=>setRow("commissionSchedule",i,{hstTreatment:v}),HST_TREATMENTS)}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{r.hstTreatment!=="NOT_APPLICABLE"?inp(r.hstRatePercent,v=>setRow("commissionSchedule",i,{hstRatePercent:v}),"number",{min:0,max:100,step:"0.01"}):inp(r.hstExemptionReason,v=>setRow("commissionSchedule",i,{hstExemptionReason:v}))}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{select(r.paymentTrigger,v=>setRow("commissionSchedule",i,{paymentTrigger:v}),[{value:"LEASE_START",label:"Lease commencement"},{value:"SIGNING",label:"Signing"},{value:"EACH_PERIOD",label:"Each period"},{value:"CUSTOM",label:"Custom"}])}{r.paymentTrigger==="CUSTOM"&&field("Describe trigger",inp(r.paymentTriggerDescription,v=>setRow("commissionSchedule",i,{paymentTriggerDescription:v})))}</td>
      <td style={{padding:5,borderBottom:"1px solid #edf0f4"}}>{!readOnly&&<button type="button" title="Remove period" onClick={()=>removeRow("commissionSchedule",i)} disabled={data.commissionSchedule.length<=1} style={{padding:"5px 8px"}}>×</button>}</td>
     </tr>)}</tbody>
    </table>
   </div>
   {(data.commissionSchedule||[]).some(r=>r.base==="CUSTOM")&&<div style={rowGrid}>{data.commissionSchedule.map((r,i)=>r.base==="CUSTOM"?field((r.periodLabel||"Period "+(i+1))+" signed formula",inp(r.customFormulaDescription,v=>setRow("commissionSchedule",i,{customFormulaDescription:v}))):null)}</div>}
  </div>
  <div style={{border:"1px solid "+(result.valid?"#86efac":"#fca5a5"),background:result.valid?"#f0fdf4":"#fff7f7",borderRadius:6,padding:10,display:"grid",gap:6}}>
   <b>{result.valid?"Calculation preview":"Validation required"}</b>
   {result.errors.map((x,i)=><div key={"e"+i} style={{fontSize:12,color:"#b91c1c"}}>• {x}</div>)}
   {result.warnings.map((x,i)=><div key={"w"+i} style={{fontSize:12,color:"#92400e"}}>Review warning: {x}</div>)}
   {result.valid&&<div style={rowGrid}><div>Commission before HST: <b>{money(result.subtotal)}</b></div><div>HST: <b>{money(result.hst)}</b></div><div>Total: <b>{money(result.total)}</b></div></div>}
   {result.requiresAdminReview&&<b style={{fontSize:12,color:"#92400e"}}>Administrator review required before relying on this calculation.</b>}
  </div>
 </section>;
}
