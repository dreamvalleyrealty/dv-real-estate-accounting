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
  <div style={{display:"grid",gap:8}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:8}}><b>Rent schedule</b>{!readOnly&&<button type="button" onClick={()=>addRow("rentSchedule",rentDefault)} style={{padding:"6px 9px"}}>+ Add rent period</button>}</div>
   {(data.rentSchedule||[]).map((r,i)=><div key={i} style={{border:"1px solid #e2e8f0",borderRadius:6,padding:9,display:"grid",gap:8}}>
    <div style={rowGrid}>
     {field("Period label",inp(r.periodLabel,v=>setRow("rentSchedule",i,{periodLabel:v})))}
     {field("From lease year",inp(r.startPeriod,v=>setRow("rentSchedule",i,{startPeriod:v}),"number",{min:1}))}
     {field("To lease year",inp(r.endPeriod,v=>setRow("rentSchedule",i,{endPeriod:v}),"number",{min:1}))}
     {field("Annual base rent ($)",inp(r.baseRent,v=>setRow("rentSchedule",i,{baseRent:v}),"number",{min:0,step:"0.01"}))}
     {field("Annual additional rent ($)",inp(r.additionalRent,v=>setRow("rentSchedule",i,{additionalRent:v}),"number",{min:0,step:"0.01"}))}
     {field("Rent increase",select(r.escalationType,v=>setRow("rentSchedule",i,{escalationType:v}),[{value:"NONE",label:"No increase"},{value:"PERCENT",label:"Percentage increase"},{value:"FIXED",label:"Fixed annual increase"},{value:"CARRY_FORWARD",label:"Carry forward"}]))}
     {r.escalationType!=="NONE"&&field(r.escalationType==="PERCENT"?"Increase (%)":"Annual increase ($)",inp(r.escalationValue,v=>setRow("rentSchedule",i,{escalationValue:v}),"number",{min:0,step:"0.01"}))}
    </div>{!readOnly&&data.rentSchedule.length>1&&<button type="button" onClick={()=>removeRow("rentSchedule",i)} style={{justifySelf:"start"}}>Remove rent period</button>}
   </div>)}
  </div>
  <div style={{display:"grid",gap:8}}>
   <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:8}}><b>Commission rates by lease period</b>{!readOnly&&<button type="button" onClick={()=>addRow("commissionSchedule",commissionDefault)} style={{padding:"6px 9px"}}>+ Add commission period</button>}</div>
   {(data.commissionSchedule||[]).map((r,i)=><div key={i} style={{border:"1px solid #e2e8f0",borderRadius:6,padding:9,display:"grid",gap:8}}>
    <div style={rowGrid}>
     {field("Period label",inp(r.periodLabel,v=>setRow("commissionSchedule",i,{periodLabel:v})))}
     {field("From lease year",inp(r.startPeriod,v=>setRow("commissionSchedule",i,{startPeriod:v}),"number",{min:1}))}
     {field("To lease year",inp(r.endPeriod,v=>setRow("commissionSchedule",i,{endPeriod:v}),"number",{min:1}))}
     {field("Calculation method",select(r.base,v=>setRow("commissionSchedule",i,{base:v}),COMMISSION_BASES))}
     {["BASE_RENT","GROSS_RENT","BASE_AND_ADDITIONAL_RENT"].includes(r.base)&&field("Commission rate (%)",inp(r.ratePercent,v=>setRow("commissionSchedule",i,{ratePercent:v}),"number",{min:0,max:100,step:"0.01"}))}
     {["FIXED_AMOUNT","PER_SQUARE_FOOT"].includes(r.base)&&field(r.base==="PER_SQUARE_FOOT"?"Fee per sq. ft. ($)":"Fixed fee ($)",inp(r.fixedAmount,v=>setRow("commissionSchedule",i,{fixedAmount:v}),"number",{min:0,step:"0.01"}))}
     {r.base==="MONTHS_OF_RENT"&&field("Months of base rent",inp(r.monthsOfRent,v=>setRow("commissionSchedule",i,{monthsOfRent:v}),"number",{min:0,step:"0.01"}))}
    </div>
    <div style={rowGrid}>
     {field("NET treatment",select(r.netTreatment,v=>setRow("commissionSchedule",i,{netTreatment:v}),NET_TREATMENTS))}
     {["LESS_SPECIFIED_DEDUCTIONS","OTHER_DEFINED"].includes(r.netTreatment)&&field("Define NET / deductions",inp(r.netDefinition,v=>setRow("commissionSchedule",i,{netDefinition:v})))}
     {r.netTreatment==="LESS_SPECIFIED_DEDUCTIONS"&&field("Deductions ($)",inp(r.deductions,v=>setRow("commissionSchedule",i,{deductions:v}),"number",{min:0,step:"0.01"}))}
     {r.netTreatment==="NET_PAYABLE_TO_COOPERATING_BROKERAGE"&&field("Agreed net payable ($)",inp(r.netPayableAmount,v=>setRow("commissionSchedule",i,{netPayableAmount:v}),"number",{min:0,step:"0.01"}))}
     {field("HST treatment",select(r.hstTreatment,v=>setRow("commissionSchedule",i,{hstTreatment:v}),HST_TREATMENTS))}
     {r.hstTreatment!=="NOT_APPLICABLE"&&field("HST rate (%)",inp(r.hstRatePercent,v=>setRow("commissionSchedule",i,{hstRatePercent:v}),"number",{min:0,max:100,step:"0.01"}))}
     {r.hstTreatment==="NOT_APPLICABLE"&&field("Reason HST not applicable",inp(r.hstExemptionReason,v=>setRow("commissionSchedule",i,{hstExemptionReason:v})))}
     {field("Payment trigger",select(r.paymentTrigger,v=>setRow("commissionSchedule",i,{paymentTrigger:v}),[{value:"LEASE_START",label:"Lease commencement"},{value:"SIGNING",label:"Signing"},{value:"EACH_PERIOD",label:"Each period"},{value:"CUSTOM",label:"Other / custom"}]))}
     {r.paymentTrigger==="CUSTOM"&&field("Describe payment trigger",inp(r.paymentTriggerDescription,v=>setRow("commissionSchedule",i,{paymentTriggerDescription:v})))}
     {r.base==="CUSTOM"&&field("Signed formula description",inp(r.customFormulaDescription,v=>setRow("commissionSchedule",i,{customFormulaDescription:v})))}
    </div>{!readOnly&&data.commissionSchedule.length>1&&<button type="button" onClick={()=>removeRow("commissionSchedule",i)} style={{justifySelf:"start"}}>Remove commission period</button>}
   </div>)}
  </div>
  <div style={{display:"grid",gap:7,borderTop:"1px solid #e2e8f0",paddingTop:10}}>
   <b>Agreement and approval</b>
   {field("Signed agreement document ID / reference",inp(data.signedAgreementDocumentId,v=>set("signedAgreementDocumentId",v)))}
   <label style={{display:"flex",gap:8,alignItems:"center",fontSize:13}}><input type="checkbox" checked={!!data.commissionAuthorityConfirmed} onChange={e=>set("commissionAuthorityConfirmed",e.target.checked)} disabled={readOnly}/> Administrator confirmed the signed agreement is the controlling commission authority</label>
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
