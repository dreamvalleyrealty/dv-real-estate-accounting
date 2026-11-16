import React,{useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {RefreshCw,FileSpreadsheet,FileText} from "lucide-react";
import * as XLSX from "xlsx";
import {jsPDF} from "jspdf";
const n=v=>Number(v||0);
const money=v=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(n(v));
const currentYear=String(new Date().getFullYear());
const agentName=a=>[a?.first_name,a?.last_name].filter(Boolean).join(" ")||a?.name||a?.email||"Unmatched agent";
export default function AgentYearEndExpenses(){
 const [rows,setRows]=useState([]),[busy,setBusy]=useState(false),[error,setError]=useState("");
 const [year,setYear]=useState(currentYear),[agent,setAgent]=useState(""),[category,setCategory]=useState(""),[basis,setBasis]=useState("all");
 const load=async()=>{
  if(!supabase)return;setBusy(true);setError("");
  try{
   const start=year+"-01-01",end=year+"-12-31";
   const [legacyRes,chargeRes]=await Promise.all([
    supabase.from("dv_agent_expenses").select("id,agent_id,expense_category,expense_date,description,quantity,unit_amount,tax_amount,total_amount,due_amount,status,deal_id,dv_agents(first_name,last_name,email,agent_number)").gte("expense_date",start).lte("expense_date",end).order("expense_date",{ascending:true}),
    supabase.from("dv_accounting_commission_charges").select("id,agent_id,charge_type,description,amount,base_amount,hst_amount,paid_amount,status,created_at,applied_to_cheque_id,service_period_start,service_period_end,hst_applicable,dv_accounting_agents(first_name,last_name,name,email,agent_number)").order("created_at",{ascending:true})
   ]);
   if(legacyRes.error)throw legacyRes.error;if(chargeRes.error)throw chargeRes.error;
   const charges=chargeRes.data||[];
   const chequeIds=[...new Set(charges.map(c=>c.applied_to_cheque_id).filter(Boolean))];
   let chequeMap={};
   if(chequeIds.length){
    const {data,error:e}=await supabase.from("dv_accounting_commission_cheques").select("id,cheque_number,cheque_date,status,issued_at").in("id",chequeIds);
    if(e)throw e;chequeMap=Object.fromEntries((data||[]).map(x=>[x.id,x]));
   }
   const legacy=(legacyRes.data||[]).map(r=>({
    id:"legacy-"+r.id,agent_id:r.agent_id,agent:agentName(r.dv_agents),email:r.dv_agents?.email||"",agent_number:r.dv_agents?.agent_number||"",
    category:r.expense_category||"Uncategorized",description:r.description||"",charge_date:r.expense_date||"",
    payment_date:"",report_date:r.expense_date||"",before_hst:n(r.total_amount)-n(r.tax_amount),hst:n(r.tax_amount),total:n(r.total_amount),
    paid:Math.max(0,n(r.total_amount)-n(r.due_amount)),outstanding:n(r.due_amount),status:r.status||"Legacy ledger",source:"Legacy expense ledger",basis:"charge"
   }));
   const modern=charges.map(c=>{
    const cheque=chequeMap[c.applied_to_cheque_id]||null;
    const applied=!!cheque||String(c.status||"").toUpperCase()==="APPLIED";
    const paymentDate=cheque?.cheque_date|| (cheque?.issued_at?String(cheque.issued_at).slice(0,10):"");
    const chargeDate=String(c.created_at||"").slice(0,10);
    const base=n(c.base_amount??c.amount),hst=n(c.hst_amount),total=base+hst;
    return {id:"charge-"+c.id,agent_id:c.agent_id,agent:agentName(c.dv_accounting_agents),email:c.dv_accounting_agents?.email||"",agent_number:c.dv_accounting_agents?.agent_number||"",
     category:c.charge_type||"Agent charge",description:c.description||"",charge_date:chargeDate,payment_date:paymentDate,report_date:paymentDate||chargeDate,
     before_hst:base,hst,total,paid:applied?total:Math.min(total,n(c.paid_amount)),outstanding:applied?0:Math.max(0,total-n(c.paid_amount)),
     status:applied?"Applied to commission cheque":(c.status||"Open"),source:"Accounting commission charges",basis:applied?"paid":"charge",cheque_number:cheque?.cheque_number||""};
   });
   const all=[...legacy,...modern].filter(r=>r.report_date>=start&&r.report_date<=end);
   setRows(all);
  }catch(e){setError(e?.message||"Could not load agent expenses.");setRows([])}
  finally{setBusy(false)}
 };
 useEffect(()=>{load()},[year]);
 const agents=useMemo(()=>Array.from(new Map(rows.map(r=>[r.agent_id,{id:r.agent_id,name:r.agent}])).values()).sort((a,b)=>a.name.localeCompare(b.name)),[rows]);
 const categories=useMemo(()=>Array.from(new Set(rows.map(r=>r.category))).sort(),[rows]);
 const filtered=useMemo(()=>rows.filter(r=>(!agent||r.agent_id===agent)&&(!category||r.category===category)&&(basis==="all"||(basis==="paid"?r.paid>0:r.outstanding>0))),[rows,agent,category,basis]);
 const summary=useMemo(()=>filtered.reduce((s,r)=>({subtotal:s.subtotal+r.before_hst,hst:s.hst+r.hst,total:s.total+r.total,paid:s.paid+r.paid,due:s.due+r.outstanding}),{subtotal:0,hst:0,total:0,paid:0,due:0}),[filtered]);
 const exportExcel=()=>{const data=filtered.map(r=>({"Report date":r.report_date,"Charge date":r.charge_date,"Payment / cheque date":r.payment_date,Agent:r.agent,Email:r.email,Category:r.category,Description:r.description,Source:r.source,"Before HST":r.before_hst,HST:r.hst,"Total charge":r.total,Paid:r.paid,Outstanding:r.outstanding,Status:r.status,"Cheque number":r.cheque_number||""}));const ws=XLSX.utils.json_to_sheet(data);const wb=XLSX.utils.book_new();XLSX.utils.book_append_sheet(wb,ws,"Agent Expenses");XLSX.writeFile(wb,"Dream-Valley-Agent-Expenses-"+year+".xlsx")};
 const exportPdf=()=>{const d=new jsPDF({orientation:"landscape"});d.setFontSize(16);d.text("Dream Valley Realty - Agent Expense Report",14,16);d.setFontSize(9);d.text("Calendar year: "+year+" | Date basis: payment/cheque date when applied; otherwise charge date",14,23);d.text("Before HST: "+money(summary.subtotal)+" | HST: "+money(summary.hst)+" | Charges: "+money(summary.total)+" | Paid/applied: "+money(summary.paid)+" | Outstanding: "+money(summary.due),14,30);let y=40;d.setFont(undefined,"bold");d.text("Date",12,y);d.text("Agent",38,y);d.text("Category / Description",90,y);d.text("HST",220,y,{align:"right"});d.text("Total",250,y,{align:"right"});d.text("Paid",275,y,{align:"right"});d.setFont(undefined,"normal");for(const r of filtered){y+=7;if(y>190){d.addPage();y=18}d.text(String(r.report_date||"").slice(0,10),12,y);d.text(r.agent.slice(0,25),38,y);d.text((r.category+" - "+r.description).slice(0,65),90,y);d.text(money(r.hst),220,y,{align:"right"});d.text(money(r.total),250,y,{align:"right"});d.text(money(r.paid),275,y,{align:"right"})}d.save("Dream-Valley-Agent-Expenses-"+year+".pdf")};
 return <div><div className="pagehead"><div><h1>Year-End Agent Expense Report</h1><p>Legacy expense ledger and accounting agent charges. Applied charges use the commission cheque date; open charges use the charge date.</p></div><div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button className="secondary" onClick={exportPdf} disabled={!filtered.length}><FileText size={15}/> PDF</button><button className="primary" onClick={exportExcel} disabled={!filtered.length}><FileSpreadsheet size={15}/> Excel</button></div></div>
 {error&&<div className="error">{error}</div>}
 <section className="panel"><div style={{display:"flex",gap:12,flexWrap:"wrap",alignItems:"end"}}><label>Calendar year<input type="number" min="2000" max="2100" value={year} onChange={e=>setYear(e.target.value)}/></label><label>Agent<select value={agent} onChange={e=>setAgent(e.target.value)}><option value="">All agents</option>{agents.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label><label>Category<select value={category} onChange={e=>setCategory(e.target.value)}><option value="">All categories</option>{categories.map(x=><option key={x}>{x}</option>)}</select></label><label>Date / balance<select value={basis} onChange={e=>setBasis(e.target.value)}><option value="all">All charges</option><option value="paid">Paid / applied</option><option value="outstanding">Outstanding</option></select></label><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
 <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(155px,1fr))",gap:12,margin:"18px 0"}}><div className="card"><div className="muted">Before HST</div><div className="metric">{money(summary.subtotal)}</div></div><div className="card"><div className="muted">HST</div><div className="metric">{money(summary.hst)}</div></div><div className="card"><div className="muted">Total charges</div><div className="metric">{money(summary.total)}</div></div><div className="card"><div className="muted">Paid / applied</div><div className="metric">{money(summary.paid)}</div></div><div className="card"><div className="muted">Outstanding</div><div className="metric">{money(summary.due)}</div></div></div>
 {busy?<p className="muted">Loading expenses…</p>:<div style={{overflowX:"auto"}}><table className="data-table" style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["Report date","Agent","Category","Description","Before HST","HST","Total","Paid / applied","Outstanding","Status"].map(h=><th key={h} style={{textAlign:"left",padding:9}}>{h}</th>)}</tr></thead><tbody>{filtered.map(r=><tr key={r.id} style={{borderTop:"1px solid #e5e7eb"}}><td style={{padding:9,whiteSpace:"nowrap"}}>{r.report_date}</td><td style={{padding:9}}>{r.agent}</td><td style={{padding:9}}>{r.category}</td><td style={{padding:9}}>{r.description}{r.cheque_number?" (Cheque "+r.cheque_number+")":""}</td><td style={{padding:9}}>{money(r.before_hst)}</td><td style={{padding:9}}>{money(r.hst)}</td><td style={{padding:9}}>{money(r.total)}</td><td style={{padding:9}}>{money(r.paid)}</td><td style={{padding:9}}>{money(r.outstanding)}</td><td style={{padding:9}}>{r.status}</td></tr>)}</tbody></table>{!filtered.length&&<p className="muted">No expense records match this year and filter.</p>}</div>}
 <p className="muted" style={{marginTop:12}}>Sources: dv_agent_expenses and dv_accounting_commission_charges. Recurring subscription definitions and charge-payment records are not added as separate expenses. A commission charge marked APPLIED is treated as paid through its commission cheque; open charges remain outstanding. Confirm accounting and tax treatment with your accountant before using this as a tax filing statement.</p>
 </section></div>
}
