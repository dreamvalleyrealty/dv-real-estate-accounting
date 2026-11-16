import React,{useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {Plus,RefreshCw,ReceiptText,Wallet,CheckCircle2,AlertCircle} from "lucide-react";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const dateToday=()=>{const d=new Date();return [d.getFullYear(),String(d.getMonth()+1).padStart(2,"0"),String(d.getDate()).padStart(2,"0")].join("-")};

export default function AgentInvoices({agentId=null,adminMode=false}){
 const [agents,setAgents]=useState([]),[invoices,setInvoices]=useState([]),[payments,setPayments]=useState([]);
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState("");
 const [showCreate,setShowCreate]=useState(false),[showPayment,setShowPayment]=useState(null);
 const [form,setForm]=useState({agent_id:"",invoice_date:dateToday(),due_date:"",description:"",subtotal:"",tax_rate:"13",notes:""});
 const [paymentForm,setPaymentForm]=useState({amount:"",payment_date:dateToday(),method:"E-transfer",reference_number:"",notes:""});
 const load=useCallback(async()=>{
  if(!supabase)return;
  setBusy(true);setError("");
  try{
   let aq=supabase.from("dv_agent_invoices").select("*,dv_accounting_agents(id,name,first_name,last_name,email)").order("created_at",{ascending:false});
   if(!adminMode)aq=aq.eq("agent_id",agentId);
   const {data,error:e}=await aq;if(e)throw e;
   const ids=(data||[]).map(x=>x.id);
   let p=[];
   if(ids.length){const{data:pd,error:pe}=await supabase.from("dv_agent_invoice_payments").select("*").in("invoice_id",ids).order("payment_date",{ascending:false});if(pe)throw pe;p=pd||[]}
   setInvoices(data||[]);setPayments(p);
   if(adminMode){const{data:ad,error:ae}=await supabase.from("dv_accounting_agents").select("id,name,first_name,last_name,email").eq("active",true).order("display_name");if(ae)throw ae;setAgents(ad||[])}
  }catch(e){setError(e?.message||"Unable to load invoices.")}finally{setBusy(false)}
 },[agentId,adminMode]);
 useEffect(()=>{load()},[load]);
 const totals=useMemo(()=>({outstanding:invoices.reduce((s,x)=>s+Number(x.balance_amount||0),0),paid:invoices.reduce((s,x)=>s+Number(x.paid_amount||0),0)}),[invoices]);
 const createInvoice=async e=>{
  e.preventDefault();setBusy(true);setError("");setNotice("");
  try{
   const subtotal=Number(form.subtotal),rate=Number(form.tax_rate||0);
   if(!form.agent_id||!form.description.trim()||!Number.isFinite(subtotal)||subtotal<=0||rate<0)throw new Error("Select an agent and enter a valid description and amount.");
   const tax=Number((subtotal*rate/100).toFixed(2)),total=Number((subtotal+tax).toFixed(2));
   const{error:e1}=await supabase.from("dv_agent_invoices").insert({agent_id:form.agent_id,invoice_date:form.invoice_date,due_date:form.due_date||null,description:form.description.trim(),subtotal,tax_rate:rate,tax_amount:tax,total_amount:total,paid_amount:0,balance_amount:total,status:"Open",notes:form.notes||null});
   if(e1)throw e1;
   setShowCreate(false);setForm({agent_id:"",invoice_date:dateToday(),due_date:"",description:"",subtotal:"",tax_rate:"13",notes:""});setNotice("Invoice created.");await load();
  }catch(e){setError(e?.message||"Invoice could not be created.")}finally{setBusy(false)}
 };
 const recordPayment=async e=>{
  e.preventDefault();if(!showPayment)return;setBusy(true);setError("");setNotice("");
  try{
   const amount=Number(paymentForm.amount);
   if(!Number.isFinite(amount)||amount<=0||amount>Number(showPayment.balance_amount)+0.005)throw new Error("Enter a payment greater than zero and no more than the outstanding balance.");
   const{error:e1}=await supabase.from("dv_agent_invoice_payments").insert({invoice_id:showPayment.id,agent_id:showPayment.agent_id,amount,payment_date:paymentForm.payment_date,payment_method:paymentForm.method,reference_number:paymentForm.reference_number||null,notes:paymentForm.notes||null});
   if(e1)throw e1;
   setShowPayment(null);setPaymentForm({amount:"",payment_date:dateToday(),method:"E-transfer",reference_number:"",notes:""});setNotice("Payment recorded.");await load();
  }catch(e){setError(e?.message||"Payment could not be recorded.")}finally{setBusy(false)}
 };
 return <div>
  <div className="pagehead"><div><h1>{adminMode?"Agent Invoices":"Invoices & Payments"}</h1><p>{adminMode?"Create invoices and record payments received from agents.":"Review your brokerage invoices and payment history."}</p></div>{adminMode&&<button className="primary" onClick={()=>{setError("");setShowCreate(true)}}><Plus size={16}/> Create Invoice</button>}</div>
  {error&&<div className="error" role="alert" style={{marginBottom:12}}><AlertCircle size={16}/> {error}</div>}{notice&&<div className="notice" role="status" style={{marginBottom:12}}><CheckCircle2 size={16}/> {notice}</div>}
  <div className="cards" style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(190px,1fr))",gap:12,marginBottom:16}}><div className="card"><div className="muted">Outstanding</div><div className="metric">{money(totals.outstanding)}</div></div><div className="card"><div className="muted">Payments recorded</div><div className="metric">{money(totals.paid)}</div></div><div className="card"><div className="muted">Invoices</div><div className="metric">{invoices.length}</div></div></div>
  <div className="panel"><div className="panelhead" style={{display:"flex",justifyContent:"space-between",alignItems:"center",gap:10}}><h2><ReceiptText size={18}/> Invoice register</h2><button className="secondary" onClick={load} disabled={busy}><RefreshCw size={15}/> Refresh</button></div>
   {busy&&!invoices.length?<p className="muted">Loading invoices…</p>:!invoices.length?<p className="muted">No invoices found.</p>:<div style={{overflowX:"auto"}}><table className="data-table" style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["Invoice","Agent","Date","Due","Total","Paid","Balance","Status",...(adminMode?["Action"]:[])].map(x=><th key={x} style={{textAlign:"left",padding:10}}>{x}</th>)}</tr></thead><tbody>{invoices.map(inv=><tr key={inv.id} style={{borderTop:"1px solid #e5e7eb"}}><td style={{padding:10}}><strong>{inv.invoice_number||"Pending"}</strong><div className="muted">{inv.description}</div></td><td style={{padding:10}}>{inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||inv.dv_accounting_agents?.email||"—"}</td><td style={{padding:10}}>{inv.invoice_date||"—"}</td><td style={{padding:10}}>{inv.due_date||"—"}</td><td style={{padding:10}}>{money(inv.total_amount)}</td><td style={{padding:10}}>{money(inv.paid_amount)}</td><td style={{padding:10}}><strong>{money(inv.balance_amount)}</strong></td><td style={{padding:10}}><span className="badge">{inv.status}</span></td>{adminMode&&<td style={{padding:10}}>{Number(inv.balance_amount)>0&&<button className="secondary" onClick={()=>{setPaymentForm({...paymentForm,amount:String(inv.balance_amount)});setShowPayment(inv)}}><Wallet size={14}/> Record payment</button>}</td>}</tr>)}</tbody></table></div>}
  </div>
  {showCreate&&<div className="overlay"><div className="modal" style={{maxWidth:620}}><div className="modalhead"><h2>Create agent invoice</h2><button className="iconbtn" onClick={()=>setShowCreate(false)}>×</button></div><form onSubmit={createInvoice} style={{display:"grid",gap:12}}><label>Agent<select required value={form.agent_id} onChange={e=>setForm({...form,agent_id:e.target.value})}><option value="">Select agent</option>{agents.map(a=><option key={a.id} value={a.id}>{a.name||[a.first_name,a.last_name].filter(Boolean).join(" ")||a.email}</option>)}</select></label><label>Invoice date<input type="date" required value={form.invoice_date} onChange={e=>setForm({...form,invoice_date:e.target.value})}/></label><label>Due date<input type="date" value={form.due_date} onChange={e=>setForm({...form,due_date:e.target.value})}/></label><label>Description<input required value={form.description} onChange={e=>setForm({...form,description:e.target.value})} placeholder="Desk fee, transaction fee, etc."/></label><div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:10}}><label>Amount before HST<input type="number" min="0.01" step="0.01" required value={form.subtotal} onChange={e=>setForm({...form,subtotal:e.target.value})}/></label><label>HST rate (%)<input type="number" min="0" step="0.01" value={form.tax_rate} onChange={e=>setForm({...form,tax_rate:e.target.value})}/></label></div><label>Notes<textarea value={form.notes} onChange={e=>setForm({...form,notes:e.target.value})}/></label><div className="notice">E-transfer payment instructions: admin@dvrealty.ca. Include the invoice number in the transfer message.</div><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowCreate(false)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Create invoice"}</button></div></form></div></div>}
  {showPayment&&<div className="overlay"><div className="modal" style={{maxWidth:540}}><div className="modalhead"><h2>Record payment — {showPayment.invoice_number}</h2><button className="iconbtn" onClick={()=>setShowPayment(null)}>×</button></div><form onSubmit={recordPayment} style={{display:"grid",gap:12}}><p>Outstanding balance: <strong>{money(showPayment.balance_amount)}</strong></p><label>Payment amount<input type="number" min="0.01" max={showPayment.balance_amount} step="0.01" required value={paymentForm.amount} onChange={e=>setPaymentForm({...paymentForm,amount:e.target.value})}/></label><label>Payment date<input type="date" required value={paymentForm.payment_date} onChange={e=>setPaymentForm({...paymentForm,payment_date:e.target.value})}/></label><label>Method<select value={paymentForm.method} onChange={e=>setPaymentForm({...paymentForm,method:e.target.value})}><option>E-transfer</option><option>Cheque</option><option>Cash</option><option>Credit card (Square)</option><option>Other</option></select></label><label>Reference number<input value={paymentForm.reference_number} onChange={e=>setPaymentForm({...paymentForm,reference_number:e.target.value})}/></label><label>Notes<textarea value={paymentForm.notes} onChange={e=>setPaymentForm({...paymentForm,notes:e.target.value})}/></label><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowPayment(null)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Save payment"}</button></div></form></div></div>}
 </div>
}
