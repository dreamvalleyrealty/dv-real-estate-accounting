import React,{useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {Plus,RefreshCw,ReceiptText,Wallet,CheckCircle2,AlertCircle,Download,History,Mail} from "lucide-react";
import {jsPDF} from "jspdf";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const dateToday=()=>{const d=new Date();return [d.getFullYear(),String(d.getMonth()+1).padStart(2,"0"),String(d.getDate()).padStart(2,"0")].join("-")};

export default function AgentInvoices({agentId=null,adminMode=false}){
 const [agents,setAgents]=useState([]),[invoices,setInvoices]=useState([]),[payments,setPayments]=useState([]);
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState(""),[sendingInvoice,setSendingInvoice]=useState(null);
 const [showCreate,setShowCreate]=useState(false),[showPayment,setShowPayment]=useState(null),[expandedInvoice,setExpandedInvoice]=useState(null);
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
 const buildInvoicePdf=inv=>{
  const doc=new jsPDF({unit:"mm",format:"a4"}),left=18,right=192;
  doc.setFillColor(15,33,65);doc.rect(0,0,210,38,"F");
  doc.setTextColor(255,255,255);doc.setFontSize(17);doc.text("DREAM VALLEY REALTY INC.",left,17);
  doc.setFontSize(9);doc.text("BROKERAGE",left,24);doc.setFontSize(18);doc.text("INVOICE",right,18,{align:"right"});
  doc.setTextColor(25,35,50);doc.setFontSize(10);
  const agent=inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||inv.dv_accounting_agents?.email||"Agent";
  doc.text("Bill to: "+agent,left,52);doc.text("Invoice #: "+(inv.invoice_number||""),right,52,{align:"right"});
  doc.text("Invoice date: "+(inv.invoice_date||""),left,60);doc.text("Due date: "+(inv.due_date||"—"),right,60,{align:"right"});
  doc.setDrawColor(210,215,225);doc.line(left,69,right,69);
  doc.setFont(undefined,"bold");doc.text("Description",left,78);doc.text("Amount",right,78,{align:"right"});
  doc.setFont(undefined,"normal");const lines=doc.splitTextToSize(String(inv.description||""),125);doc.text(lines,left,88);
  doc.text(money(inv.subtotal),right,88,{align:"right"});
  let y=105;doc.line(left,y,right,y);y+=9;
  [["Subtotal",inv.subtotal],["HST",inv.tax_amount],["Total",inv.total_amount],["Paid",inv.paid_amount],["Balance due",inv.balance_amount]].forEach(([label,value],i)=>{if(i===2||i===4)doc.setFont(undefined,"bold");doc.text(label,left+95,y);doc.text(money(value),right,y,{align:"right"});doc.setFont(undefined,"normal");y+=8});
  y+=8;doc.setFontSize(10);doc.setFont(undefined,"bold");doc.text("Payment by e-transfer",left,y);y+=7;doc.setFont(undefined,"normal");doc.text("Send payment to admin@dvrealty.ca",left,y);y+=6;doc.text("Include invoice number "+(inv.invoice_number||"")+" in the transfer message.",left,y);
  if(inv.notes){y+=12;doc.setFont(undefined,"bold");doc.text("Notes",left,y);y+=6;doc.setFont(undefined,"normal");doc.text(doc.splitTextToSize(String(inv.notes),170),left,y)}
  return doc;
 };
 const makeInvoicePdf=inv=>buildInvoicePdf(inv).save("Invoice-"+(inv.invoice_number||inv.id)+".pdf");
 const escapeHtml=value=>String(value??"").replace(/[&<>"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[ch]));
 const sendInvoice=async inv=>{
  const recipient=String(inv.dv_accounting_agents?.email||"").trim();
  if(!recipient){setError("This agent does not have an email address on their accounting profile.");return;}
  setSendingInvoice(inv.id);setError("");setNotice("");
  try{
   const doc=buildInvoicePdf(inv),dataUri=doc.output("datauristring"),base64=dataUri.split(",")[1]||"";
   const htmlBody=`<p>Hello ${escapeHtml(inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||"")},</p><p>Please find attached your Dream Valley Realty invoice <strong>${escapeHtml(inv.invoice_number)}</strong>.</p><p><strong>Total:</strong> ${money(inv.total_amount)}<br/><strong>Paid:</strong> ${money(inv.paid_amount)}<br/><strong>Balance due:</strong> ${money(inv.balance_amount)}<br/><strong>Due date:</strong> ${escapeHtml(inv.due_date||"Not specified")}</p><p>For e-transfer, send payment to <strong>admin@dvrealty.ca</strong> and include invoice number ${escapeHtml(inv.invoice_number)} in the message.</p><p>Thank you,<br/>Dream Valley Realty Inc.</p>`;
   const {data,error:e}=await supabase.functions.invoke("zoho-mail-send",{body:{documentType:"AGENT_INVOICE",invoiceId:inv.id,invoiceNumber:inv.invoice_number,to:recipient,subject:"Dream Valley Realty Invoice "+inv.invoice_number,htmlBody,attachmentName:"Invoice-"+inv.invoice_number+".pdf",attachmentBase64:base64,senderMode:"admin"}});
   if(e)throw e;if(data?.error)throw new Error(data.error);
   setNotice("Zoho accepted the invoice email for "+recipient+". This does not confirm final delivery.");
  }catch(e){setError(e?.message||"Could not send the invoice email.");}
  finally{setSendingInvoice(null)}
 };
 const invoicePayments=id=>payments.filter(p=>p.invoice_id===id);
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
   {busy&&!invoices.length?<p className="muted">Loading invoices…</p>:!invoices.length?<p className="muted">No invoices found.</p>:<div style={{overflowX:"auto"}}><table className="data-table" style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["Invoice","Agent","Date","Due","Total","Paid","Balance","Status","Details"].map(x=><th key={x} style={{textAlign:"left",padding:10}}>{x}</th>)}</tr></thead><tbody>{invoices.map(inv=><React.Fragment key={inv.id}><tr style={{borderTop:"1px solid #e5e7eb"}}><td style={{padding:10}}><strong>{inv.invoice_number||"Pending"}</strong><div className="muted">{inv.description}</div></td><td style={{padding:10}}>{inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||inv.dv_accounting_agents?.email||"—"}</td><td style={{padding:10}}>{inv.invoice_date||"—"}</td><td style={{padding:10}}>{inv.due_date||"—"}</td><td style={{padding:10}}>{money(inv.total_amount)}</td><td style={{padding:10}}>{money(inv.paid_amount)}</td><td style={{padding:10}}><strong>{money(inv.balance_amount)}</strong></td><td style={{padding:10}}><span className="badge">{inv.status}</span></td><td style={{padding:10,whiteSpace:"nowrap"}}><button className="secondary" onClick={()=>makeInvoicePdf(inv)}><Download size={14}/> PDF</button> {adminMode&&<button className="secondary" onClick={()=>sendInvoice(inv)} disabled={sendingInvoice===inv.id||!inv.dv_accounting_agents?.email}><Mail size={14}/> {sendingInvoice===inv.id?"Sending…":"Email invoice"}</button>} <button className="secondary" onClick={()=>setExpandedInvoice(expandedInvoice===inv.id?null:inv.id)}><History size={14}/> History</button>{adminMode&&Number(inv.balance_amount)>0&&<> <button className="secondary" onClick={()=>{setPaymentForm({...paymentForm,amount:String(inv.balance_amount)});setShowPayment(inv)}}><Wallet size={14}/> Record payment</button></>}</td></tr>{expandedInvoice===inv.id&&<tr><td colSpan={9} style={{padding:12,background:"#f8fafc"}}><strong>Payment history</strong>{invoicePayments(inv.id).length?invoicePayments(inv.id).map(p=><div key={p.id} style={{display:"flex",gap:16,flexWrap:"wrap",padding:"7px 0",borderBottom:"1px solid #e5e7eb"}}><span>{p.payment_date}</span><span>{p.payment_method}</span><span>{p.reference_number||"No reference"}</span><strong>{money(p.amount)}</strong></div>):<p className="muted">No payments recorded yet.</p>}</td></tr>}</React.Fragment>)}</tbody></table></div>}
  </div>
  {showCreate&&<div className="overlay"><div className="modal" style={{maxWidth:620}}><div className="modalhead"><h2>Create agent invoice</h2><button className="iconbtn" onClick={()=>setShowCreate(false)}>×</button></div><form onSubmit={createInvoice} style={{display:"grid",gap:12}}><label>Agent<select required value={form.agent_id} onChange={e=>setForm({...form,agent_id:e.target.value})}><option value="">Select agent</option>{agents.map(a=><option key={a.id} value={a.id}>{a.name||[a.first_name,a.last_name].filter(Boolean).join(" ")||a.email}</option>)}</select></label><label>Invoice date<input type="date" required value={form.invoice_date} onChange={e=>setForm({...form,invoice_date:e.target.value})}/></label><label>Due date<input type="date" value={form.due_date} onChange={e=>setForm({...form,due_date:e.target.value})}/></label><label>Description<input required value={form.description} onChange={e=>setForm({...form,description:e.target.value})} placeholder="Desk fee, transaction fee, etc."/></label><div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:10}}><label>Amount before HST<input type="number" min="0.01" step="0.01" required value={form.subtotal} onChange={e=>setForm({...form,subtotal:e.target.value})}/></label><label>HST rate (%)<input type="number" min="0" step="0.01" value={form.tax_rate} onChange={e=>setForm({...form,tax_rate:e.target.value})}/></label></div><label>Notes<textarea value={form.notes} onChange={e=>setForm({...form,notes:e.target.value})}/></label><div className="notice">E-transfer payment instructions: admin@dvrealty.ca. Include the invoice number in the transfer message.</div><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowCreate(false)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Create invoice"}</button></div></form></div></div>}
  {showPayment&&<div className="overlay"><div className="modal" style={{maxWidth:540}}><div className="modalhead"><h2>Record payment — {showPayment.invoice_number}</h2><button className="iconbtn" onClick={()=>setShowPayment(null)}>×</button></div><form onSubmit={recordPayment} style={{display:"grid",gap:12}}><p>Outstanding balance: <strong>{money(showPayment.balance_amount)}</strong></p><label>Payment amount<input type="number" min="0.01" max={showPayment.balance_amount} step="0.01" required value={paymentForm.amount} onChange={e=>setPaymentForm({...paymentForm,amount:e.target.value})}/></label><label>Payment date<input type="date" required value={paymentForm.payment_date} onChange={e=>setPaymentForm({...paymentForm,payment_date:e.target.value})}/></label><label>Method<select value={paymentForm.method} onChange={e=>setPaymentForm({...paymentForm,method:e.target.value})}><option>E-transfer</option><option>Cheque</option><option>Cash</option><option>Credit card (Square)</option><option>Other</option></select></label><label>Reference number<input value={paymentForm.reference_number} onChange={e=>setPaymentForm({...paymentForm,reference_number:e.target.value})}/></label><label>Notes<textarea value={paymentForm.notes} onChange={e=>setPaymentForm({...paymentForm,notes:e.target.value})}/></label><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowPayment(null)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Save payment"}</button></div></form></div></div>}
 </div>
}
