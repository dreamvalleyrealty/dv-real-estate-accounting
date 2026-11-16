import React,{useCallback,useEffect,useMemo,useState} from "react";
import {supabase} from "./lib/supabase";
import {Plus,RefreshCw,ReceiptText,Wallet,CheckCircle2,AlertCircle,Download,History,Mail} from "lucide-react";
import {jsPDF} from "jspdf";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const dateToday=()=>{const d=new Date();return [d.getFullYear(),String(d.getMonth()+1).padStart(2,"0"),String(d.getDate()).padStart(2,"0")].join("-")};

export default function AgentInvoices({agentId=null,adminMode=false}){
 const [agents,setAgents]=useState([]),[invoices,setInvoices]=useState([]),[payments,setPayments]=useState([]),[emailLogs,setEmailLogs]=useState([]),[catalog,setCatalog]=useState([]),[addItemId,setAddItemId]=useState(""),[addItemType,setAddItemType]=useState("ITEM");
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState(""),[sendingInvoice,setSendingInvoice]=useState(null),[checkoutInvoice,setCheckoutInvoice]=useState(null);
 const [showCreate,setShowCreate]=useState(false),[showPayment,setShowPayment]=useState(null),[expandedInvoice,setExpandedInvoice]=useState(null);
 const [form,setForm]=useState({agent_id:"",invoice_date:dateToday(),due_date:"",notes:"",items:[]});
 const [paymentForm,setPaymentForm]=useState({amount:"",payment_date:dateToday(),method:"E-transfer",reference_number:"",notes:""});
 const load=useCallback(async()=>{
  if(!supabase)return;
  setBusy(true);setError("");
  try{
   let aq=supabase.from("dv_agent_invoices").select("*,dv_accounting_agents(id,name,first_name,last_name,email),dv_agent_invoice_items(*)").order("created_at",{ascending:false});
   if(!adminMode)aq=aq.eq("agent_id",agentId);
   const {data,error:e}=await aq;if(e)throw e;
   const ids=(data||[]).map(x=>x.id);
   let p=[];
   if(ids.length){const{data:pd,error:pe}=await supabase.from("dv_agent_invoice_payments").select("*").in("invoice_id",ids).order("payment_date",{ascending:false});if(pe)throw pe;p=pd||[]}
   setInvoices(data||[]);setPayments(p);let emailRows=[];if(adminMode&&ids.length){const{data:ed,error:ee}=await supabase.from("dv_accounting_email_log").select("id,agent_invoice_id,recipient_email,subject,status,sent_at,created_at,error_message").in("agent_invoice_id",ids).order("created_at",{ascending:false});if(ee)throw ee;emailRows=ed||[]}setEmailLogs(emailRows);
   if(adminMode){const[{data:ad,error:ae},{data:ci,error:ce}]=await Promise.all([supabase.from("dv_accounting_agents").select("id,name,first_name,last_name,email").eq("active",true).order("name"),supabase.from("dv_accounting_inventory_items").select("id,item_code,item_name,item_type,description,sale_price,tax_rate,pricing_tiers,is_active,stock_quantity").eq("is_active",true).in("item_type",["SELLABLE","SERVICE","GIFT"]).order("item_name")]);if(ae)throw ae;if(ce)throw ce;setAgents(ad||[]);setCatalog(ci||[])}
  }catch(e){setError(e?.message||"Unable to load invoices.")}finally{setBusy(false)}
 },[agentId,adminMode]);
 useEffect(()=>{load()},[load]);
 const totals=useMemo(()=>({outstanding:invoices.reduce((s,x)=>s+Number(x.balance_amount||0),0),paid:invoices.reduce((s,x)=>s+Number(x.paid_amount||0),0)}),[invoices]);
 let invoiceLogoPromise=null;
 const getInvoiceLogo=()=>{
  if(!invoiceLogoPromise)invoiceLogoPromise=(async()=>{
   const response=await fetch("/dv-logo.svg");
   if(!response.ok)throw new Error("Could not load the Dream Valley logo.");
   const svg=await response.text();
   const image=new Image();
   const url=URL.createObjectURL(new Blob([svg],{type:"image/svg+xml"}));
   try{
    await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src=url});
    const canvas=document.createElement("canvas");canvas.width=703;canvas.height=844;
    const context=canvas.getContext("2d");context.drawImage(image,0,0,703,844);
    return canvas.toDataURL("image/png");
   }finally{URL.revokeObjectURL(url)}
  })();
  return invoiceLogoPromise;
 };
 const buildInvoicePdf=async inv=>{
  const doc=new jsPDF({unit:"mm",format:"a4"}),left=16,right=194,width=178;
  const navy=[15,33,65],gold=[158,133,86],ink=[34,45,64],muted=[111,122,139],line=[226,230,236],pale=[247,248,250];
  const agent=inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||inv.dv_accounting_agents?.email||"Agent";
  const logo=await getInvoiceLogo();
  const items=Array.isArray(inv.dv_agent_invoice_items)?inv.dv_agent_invoice_items:[];
  const fmtDate=value=>value?new Date(value+"T00:00:00").toLocaleDateString("en-CA",{year:"numeric",month:"short",day:"numeric"}):"—";
  const text=(value,x,y,opts={})=>doc.text(String(value??""),x,y,opts);
  const addHeader=()=>{
   doc.setFillColor(...navy);doc.rect(0,0,210,49,"F");
   doc.setFillColor(...gold);doc.rect(0,48,210,1.6,"F");
   doc.addImage(logo,"PNG",left,8,19,27);
   doc.setTextColor(255,255,255);doc.setFont("helvetica","bold");doc.setFontSize(13);text("DREAM VALLEY REALTY INC.",41,18);
   doc.setFont("helvetica","normal");doc.setFontSize(8);doc.setTextColor(219,225,235);text("BROKERAGE",41,24);
   doc.setFontSize(8);text("Toronto, Ontario, Canada",41,31);
   doc.setFont("helvetica","bold");doc.setFontSize(24);doc.setTextColor(255,255,255);text("INVOICE",right,20,{align:"right"});
   doc.setFont("helvetica","normal");doc.setFontSize(9);doc.setTextColor(226,231,240);text("# "+(inv.invoice_number||"DRAFT"),right,28,{align:"right"});
  };
  const addFooter=()=>{
   doc.setDrawColor(...line);doc.line(left,282,right,282);
   doc.setFont("helvetica","normal");doc.setFontSize(7.5);doc.setTextColor(...muted);
   text("DREAM VALLEY REALTY INC.  •  Thank you for your business.",left,288);
   text("Page "+doc.internal.getNumberOfPages(),right,288,{align:"right"});
  };
  addHeader();
  doc.setTextColor(...ink);doc.setFont("helvetica","bold");doc.setFontSize(9);text("BILL TO",left,63);
  doc.setFont("helvetica","normal");doc.setFontSize(11);text(agent,left,71);
  doc.setFontSize(8.5);doc.setTextColor(...muted);text(inv.dv_accounting_agents?.email||"",left,77);
  doc.setFillColor(...pale);doc.roundedRect(119,57,75,27,2,2,"F");
  const meta=[["Invoice date",fmtDate(inv.invoice_date)],["Due date",fmtDate(inv.due_date)],["Status",inv.status||"Open"]];
  meta.forEach(([label,value],i)=>{const y=64+i*7;doc.setFont("helvetica","normal");doc.setFontSize(7.5);doc.setTextColor(...muted);text(label,124,y);doc.setFont("helvetica","bold");doc.setFontSize(8);doc.setTextColor(...ink);text(value,189,y,{align:"right"})});
  let y=96;
  doc.setFillColor(...navy);doc.roundedRect(left,y,width,10,1.5,1.5,"F");
  doc.setFont("helvetica","bold");doc.setFontSize(8);doc.setTextColor(255,255,255);
  text("DESCRIPTION",left+4,y+6.5);text("QTY",148,y+6.5,{align:"right"});text("UNIT PRICE",171,y+6.5,{align:"right"});text("AMOUNT",right-4,y+6.5,{align:"right"});
  y+=10;
  const rows=items.length?items:[{item_name:inv.description||"Brokerage charges",quantity:1,unit_price:Number(inv.subtotal||0),line_subtotal:Number(inv.subtotal||0),tax_rate:Number(inv.tax_rate||0),line_type:"ITEM"}];
  rows.forEach((item,index)=>{
   const name=String(item.item_name||item.description||"Item");
   const nameLines=doc.splitTextToSize(name,102);
   const rowH=Math.max(12,Math.min(24,nameLines.length*4+7));
   if(y+rowH>267){addFooter();doc.addPage();addHeader();y=61;}
   if(index%2===0){doc.setFillColor(...pale);doc.rect(left,y,width,rowH,"F")}
   doc.setFont("helvetica","bold");doc.setFontSize(8.5);doc.setTextColor(...ink);doc.text(nameLines,left+4,y+6);
   if(item.line_type==="ADD_ON"){doc.setFont("helvetica","normal");doc.setFontSize(7);doc.setTextColor(...gold);text("OPTIONAL ADD-ON",left+4,y+rowH-2)}
   doc.setFont("helvetica","normal");doc.setFontSize(8);doc.setTextColor(...ink);
   text(Number(item.quantity||1).toString(),148,y+6,{align:"right"});
   text(money(item.unit_price??item.line_subtotal),171,y+6,{align:"right"});
   text(money(item.line_subtotal??item.unit_price),right-4,y+6,{align:"right"});
   doc.setDrawColor(...line);doc.line(left,y+rowH,right,y+rowH);y+=rowH;
  });
  y+=10;
  if(y>244){addFooter();doc.addPage();addHeader();y=62;}
  const totalsX=116,totalsW=78;
  doc.setFont("helvetica","normal");doc.setFontSize(8.5);doc.setTextColor(...muted);
  [["Subtotal",inv.subtotal],["HST",inv.tax_amount]].forEach(([label,value])=>{text(label,totalsX,y);doc.setTextColor(...ink);text(money(value),right-3,y,{align:"right"});y+=7;doc.setTextColor(...muted)});
  doc.setFillColor(...navy);doc.roundedRect(totalsX,y-2,totalsW,12,1.5,1.5,"F");
  doc.setFont("helvetica","bold");doc.setFontSize(9);doc.setTextColor(255,255,255);text("TOTAL",totalsX+4,y+5.5);text(money(inv.total_amount),right-3,y+5.5,{align:"right"});y+=19;
  doc.setFont("helvetica","normal");doc.setFontSize(8);doc.setTextColor(...muted);text("Paid to date",totalsX,y);doc.setTextColor(...ink);text(money(inv.paid_amount),right-3,y,{align:"right"});y+=7;
  doc.setFont("helvetica","bold");doc.setFontSize(10);doc.setTextColor(...gold);text("BALANCE DUE",totalsX,y);text(money(inv.balance_amount),right-3,y,{align:"right"});y+=15;
  if(y>253){addFooter();doc.addPage();addHeader();y=63;}
  doc.setDrawColor(...line);doc.line(left,y,right,y);y+=9;
  doc.setFont("helvetica","bold");doc.setFontSize(9);doc.setTextColor(...ink);text("PAYMENT INFORMATION",left,y);y+=7;
  doc.setFont("helvetica","normal");doc.setFontSize(8);doc.setTextColor(...muted);
  text("E-transfer: admin@dvrealty.ca",left,y);y+=5;
  text("Please include invoice number "+(inv.invoice_number||"")+" in the transfer message.",left,y);y+=8;
  if(inv.notes){doc.setFont("helvetica","bold");doc.setTextColor(...ink);text("NOTES",left,y);y+=6;doc.setFont("helvetica","normal");doc.setTextColor(...muted);const noteLines=doc.splitTextToSize(String(inv.notes),width);doc.text(noteLines,left,y);}
  addFooter();
  return doc;
 };
 const makeInvoicePdf=async inv=>{try{const doc=await buildInvoicePdf(inv);doc.save("Invoice-"+(inv.invoice_number||inv.id)+".pdf")}catch(e){setError(e?.message||"Could not create the invoice PDF.")}};
 const escapeHtml=value=>String(value??"").replace(/[&<>"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[ch]));
 const sendInvoice=async inv=>{
  const recipient=String(inv.dv_accounting_agents?.email||"").trim();
  if(!recipient){setError("This agent does not have an email address on their accounting profile.");return;}
  setSendingInvoice(inv.id);setError("");setNotice("");
  try{
   let checkoutUrl="";
   try{
    const {data:checkoutData,error:checkoutError}=await supabase.functions.invoke("agent-invoice-square-checkout",{body:{invoice_id:inv.id}});
    if(checkoutError)throw checkoutError;if(checkoutData?.error)throw new Error(checkoutData.error);
    const candidate=String(checkoutData?.checkout_url||"");if(/^https:\/\//i.test(candidate))checkoutUrl=candidate;
   }catch(checkoutUnavailable){console.warn("Square invoice checkout link unavailable; sending invoice with e-transfer instructions.",checkoutUnavailable)}
   const doc=await buildInvoicePdf(inv),dataUri=doc.output("datauristring"),base64=dataUri.split(",")[1]||"";
   const agentName=inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||"";
   const invoiceLines=(inv.dv_agent_invoice_items||[]).map(item=>({name:item.item_name||"Item",kind:item.line_type==="ADD_ON"?"Optional add-on":"Item",qty:Number(item.quantity||1),price:Number(item.unit_price||0),amount:Number(item.line_subtotal||0)}));
   const itemRows=invoiceLines.length?invoiceLines.map(item=>"<tr><td style='padding:10px 8px;border-bottom:1px solid #e8ebf0'><strong>"+escapeHtml(item.name)+"</strong><div style='font-size:12px;color:#8a93a2'>"+escapeHtml(item.kind)+"</div></td><td style='padding:10px 8px;text-align:center;border-bottom:1px solid #e8ebf0'>"+item.qty+"</td><td style='padding:10px 8px;text-align:right;border-bottom:1px solid #e8ebf0'>"+money(item.price)+"</td><td style='padding:10px 8px;text-align:right;border-bottom:1px solid #e8ebf0'>"+money(item.amount)+"</td></tr>").join(""):"<tr><td style='padding:10px 8px'>"+escapeHtml(inv.description||"Brokerage charges")+"</td><td style='text-align:center'>1</td><td style='text-align:right'>"+money(inv.subtotal)+"</td><td style='text-align:right'>"+money(inv.subtotal)+"</td></tr>";
   const htmlBody="<div style='margin:0;background:#f4f6f9;padding:28px 12px;font-family:Arial,Helvetica,sans-serif;color:#26344b'><div style='max-width:680px;margin:0 auto;background:#fff;border:1px solid #e3e7ed;border-radius:12px;overflow:hidden'><div style='background:#0f2141;padding:26px 30px;border-bottom:4px solid #9e8556'><div style='color:#fff;font-size:19px;font-weight:700'>DREAM VALLEY REALTY INC.</div><div style='color:#d7deea;font-size:11px;margin-top:5px;letter-spacing:1px'>BROKERAGE</div></div><div style='padding:28px 30px'><p>Hello "+escapeHtml(agentName)+",</p><p>Your invoice is ready. Please review the itemized charges below. A PDF copy is attached for your records.</p><div style='background:#f7f8fa;border:1px solid #e8ebf0;border-radius:8px;padding:14px 16px;margin:20px 0'><div style='font-size:12px;color:#7b8493'>INVOICE NUMBER</div><div style='font-size:20px;font-weight:700;color:#0f2141;margin:4px 0 10px'>"+escapeHtml(inv.invoice_number)+"</div><div style='font-size:13px;color:#596579'>Invoice date: "+escapeHtml(inv.invoice_date||"—")+" &nbsp; | &nbsp; Due date: "+escapeHtml(inv.due_date||"Not specified")+"</div></div><table role='presentation' cellpadding='0' cellspacing='0' style='width:100%;border-collapse:collapse;font-size:13px'><thead><tr style='background:#0f2141;color:#fff'><th style='padding:10px 8px;text-align:left'>Description</th><th style='padding:10px 8px;text-align:center'>Qty</th><th style='padding:10px 8px;text-align:right'>Unit price</th><th style='padding:10px 8px;text-align:right'>Amount</th></tr></thead><tbody>"+itemRows+"</tbody></table><table role='presentation' cellpadding='0' cellspacing='0' style='width:100%;max-width:310px;margin:18px 0 18px auto;font-size:13px'><tr><td style='padding:5px;color:#687386'>Subtotal</td><td style='padding:5px;text-align:right'>"+money(inv.subtotal)+"</td></tr><tr><td style='padding:5px;color:#687386'>HST</td><td style='padding:5px;text-align:right'>"+money(inv.tax_amount)+"</td></tr><tr><td style='padding:9px;background:#0f2141;color:#fff;font-weight:700'>Invoice total</td><td style='padding:9px;background:#0f2141;color:#fff;text-align:right;font-weight:700'>"+money(inv.total_amount)+"</td></tr><tr><td style='padding:5px;color:#687386'>Paid to date</td><td style='padding:5px;text-align:right'>"+money(inv.paid_amount)+"</td></tr><tr><td style='padding:8px;color:#9e8556;font-weight:700;font-size:15px'>BALANCE DUE</td><td style='padding:8px;text-align:right;color:#9e8556;font-weight:700;font-size:15px'>"+money(inv.balance_amount)+"</td></tr></table>"+(checkoutUrl?"<div style='text-align:center;margin:26px 0 22px'><a href='"+escapeHtml(checkoutUrl)+"' style='display:inline-block;background:#9e8556;color:#fff;text-decoration:none;font-weight:700;padding:14px 26px;border-radius:6px'>PAY BY CREDIT CARD</a><div style='font-size:11px;color:#8791a1;margin-top:9px'>Secure payment processed by Square</div></div>":"<p style='margin:22px 0;color:#687386;font-size:13px'>For credit-card payment, please contact the office to request a payment link.</p>")+"<div style='border-top:1px solid #e8ebf0;padding-top:18px;font-size:13px;line-height:1.6;color:#596579'><strong style='color:#26344b'>Prefer e-transfer?</strong><br/>Send payment to <strong>admin@dvrealty.ca</strong> and include invoice number "+escapeHtml(inv.invoice_number)+" in the transfer message.</div>"+(inv.notes?"<div style='margin-top:16px;padding:12px;background:#f7f8fa;border-radius:6px;font-size:12px'><strong>Notes:</strong> "+escapeHtml(inv.notes)+"</div>":"")+"<p style='margin-top:24px'>Thank you,<br/><strong>Dream Valley Realty Inc.</strong></p></div><div style='background:#f7f8fa;padding:14px 30px;color:#8a93a2;font-size:11px'>This email was sent by Dream Valley Realty Inc. Please keep it for your records.</div></div></div>";
   const {data,error:e}=await supabase.functions.invoke("zoho-mail-send",{body:{documentType:"AGENT_INVOICE",invoiceId:inv.id,invoiceNumber:inv.invoice_number,to:recipient,subject:"Dream Valley Realty Invoice "+inv.invoice_number,htmlBody,attachmentName:"Invoice-"+inv.invoice_number+".pdf",attachmentBase64:base64,senderMode:"admin"}});
   if(e)throw e;if(data?.error)throw new Error(data.error);
   setNotice("Invoice email accepted by Zoho for "+recipient+" and recorded in invoice history."+(checkoutUrl?" Credit-card payment link included.":" Card payment link was unavailable; e-transfer instructions were included.")+" This does not confirm final delivery.");await load();
  }catch(e){setError(e?.message||"Could not send the invoice email.");}
  finally{setSendingInvoice(null)}
 };
 const startSquareCheckout=async inv=>{
  setCheckoutInvoice(inv.id);setError("");setNotice("");
  try{
   const {data,error:e}=await supabase.functions.invoke("agent-invoice-square-checkout",{body:{invoice_id:inv.id}});
   if(e)throw e;if(data?.error)throw new Error(data.error);
   if(!data?.checkout_url)throw new Error("Square did not return a checkout link.");
   window.open(data.checkout_url,"_blank","noopener,noreferrer");
   setNotice("Square checkout opened for invoice "+inv.invoice_number+". Your invoice will update after Square confirms payment.");
  }catch(e){setError(e?.message||"Could not start Square checkout.");}
  finally{setCheckoutInvoice(null)}
 };
 const invoicePayments=id=>payments.filter(p=>p.invoice_id===id);
 const createInvoice=async e=>{
  e.preventDefault();setBusy(true);setError("");setNotice("");
  try{
   if(!form.agent_id||!form.items.length)throw new Error("Select an agent and add at least one inventory item or add-on.");
   const lines=form.items.map(x=>{const qty=Number(x.quantity),price=Number(x.unit_price),rate=Number(x.tax_rate);if(!Number.isInteger(qty)||qty<1||!Number.isFinite(price)||price<0||!Number.isFinite(rate)||rate<0)throw new Error("Check each item's quantity, price and HST rate.");const sub=Number((qty*price).toFixed(2));return {inventory_item_id:x.id,item_code:x.item_code,item_name:x.item_name,line_type:x.line_type,quantity:qty,unit_price:price,tax_rate:rate,line_subtotal:sub,line_tax:Number((sub*rate/100).toFixed(2)),line_total:Number((sub+sub*rate/100).toFixed(2))}});
   const subtotal=Number(lines.reduce((s,x)=>s+x.line_subtotal,0).toFixed(2)),tax=Number(lines.reduce((s,x)=>s+x.line_tax,0).toFixed(2)),total=Number((subtotal+tax).toFixed(2)),rates=[...new Set(lines.map(x=>x.tax_rate))];
   const description=lines.map(x=>(x.line_type==="ADD_ON"?"Add-on: ":"")+x.item_name+" × "+x.quantity).join("; ");
   const {error:e1}=await supabase.rpc("dv_create_agent_invoice_with_items",{p_invoice:{agent_id:form.agent_id,invoice_date:form.invoice_date,due_date:form.due_date||null,description,subtotal,tax_rate:rates.length===1?rates[0]:0,tax_amount:tax,total_amount:total,paid_amount:0,balance_amount:total,status:"Open",notes:form.notes||null},p_items:lines});
   if(e1)throw e1;
   setShowCreate(false);setForm({agent_id:"",invoice_date:dateToday(),due_date:"",notes:"",items:[]});setNotice("Invoice created with "+lines.length+" line item(s).");await load();
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
   {busy&&!invoices.length?<p className="muted">Loading invoices…</p>:!invoices.length?<p className="muted">No invoices found.</p>:<div style={{overflowX:"auto"}}><table className="data-table" style={{width:"100%",borderCollapse:"collapse"}}><thead><tr>{["Invoice","Agent","Date","Due","Total","Paid","Balance","Status","Details"].map(x=><th key={x} style={{textAlign:"left",padding:10}}>{x}</th>)}</tr></thead><tbody>{invoices.map(inv=><React.Fragment key={inv.id}><tr style={{borderTop:"1px solid #e5e7eb"}}><td style={{padding:10}}><strong>{inv.invoice_number||"Pending"}</strong><div className="muted">{inv.description}</div></td><td style={{padding:10}}>{inv.dv_accounting_agents?.name||[inv.dv_accounting_agents?.first_name,inv.dv_accounting_agents?.last_name].filter(Boolean).join(" ")||inv.dv_accounting_agents?.email||"—"}</td><td style={{padding:10}}>{inv.invoice_date||"—"}</td><td style={{padding:10}}>{inv.due_date||"—"}</td><td style={{padding:10}}>{money(inv.total_amount)}</td><td style={{padding:10}}>{money(inv.paid_amount)}</td><td style={{padding:10}}><strong>{money(inv.balance_amount)}</strong></td><td style={{padding:10}}><span className="badge">{inv.status}</span></td><td style={{padding:10,whiteSpace:"nowrap"}}><button className="secondary" onClick={()=>makeInvoicePdf(inv)}><Download size={14}/> PDF</button> {adminMode&&<button className="secondary" onClick={()=>sendInvoice(inv)} disabled={sendingInvoice===inv.id||!inv.dv_accounting_agents?.email}><Mail size={14}/> {sendingInvoice===inv.id?"Sending…":"Email invoice"}</button>} {!adminMode&&Number(inv.balance_amount)>0&&<button className="primary" onClick={()=>startSquareCheckout(inv)} disabled={checkoutInvoice===inv.id}><Wallet size={14}/> {checkoutInvoice===inv.id?"Opening…":"Pay by card"}</button>} <button className="secondary" onClick={()=>setExpandedInvoice(expandedInvoice===inv.id?null:inv.id)}><History size={14}/> History</button>{adminMode&&Number(inv.balance_amount)>0&&<> <button className="secondary" onClick={()=>{setPaymentForm({...paymentForm,amount:String(inv.balance_amount)});setShowPayment(inv)}}><Wallet size={14}/> Record payment</button></>}</td></tr>{expandedInvoice===inv.id&&<tr><td colSpan={9} style={{padding:12,background:"#f8fafc"}}><strong>Payment history</strong>{invoicePayments(inv.id).length?invoicePayments(inv.id).map(p=><div key={p.id} style={{display:"flex",gap:16,flexWrap:"wrap",padding:"7px 0",borderBottom:"1px solid #e5e7eb"}}><span>{p.payment_date}</span><span>{p.payment_method}</span><span>{p.reference_number||"No reference"}</span><strong>{money(p.amount)}</strong></div>):<p className="muted">No payments recorded yet.</p>}<div style={{marginTop:18}}><strong>Email history</strong>{emailLogs.filter(x=>x.agent_invoice_id===inv.id).length?emailLogs.filter(x=>x.agent_invoice_id===inv.id).map(x=><div key={x.id} style={{display:"flex",gap:12,flexWrap:"wrap",alignItems:"center",padding:"8px 0",borderBottom:"1px solid #e5e7eb"}}><span>{x.sent_at?new Date(x.sent_at).toLocaleString():new Date(x.created_at).toLocaleString()}</span><span>{x.recipient_email}</span><strong>{x.status}</strong>{x.error_message&&<span className="error">{x.error_message}</span>}</div>):<p className="muted">No invoice emails recorded yet.</p>}</div></td></tr>}</React.Fragment>)}</tbody></table></div>}
  </div>
  {showCreate&&<div className="overlay"><div className="modal" style={{maxWidth:620}}><div className="modalhead"><h2>Create agent invoice</h2><button className="iconbtn" onClick={()=>setShowCreate(false)}>×</button></div><form onSubmit={createInvoice} style={{display:"grid",gap:12}}><label>Agent<select required value={form.agent_id} onChange={e=>setForm({...form,agent_id:e.target.value})}><option value="">Select agent</option>{agents.map(a=><option key={a.id} value={a.id}>{a.name||[a.first_name,a.last_name].filter(Boolean).join(" ")||a.email}</option>)}</select></label><label>Invoice date<input type="date" required value={form.invoice_date} onChange={e=>setForm({...form,invoice_date:e.target.value})}/></label><label>Due date<input type="date" value={form.due_date} onChange={e=>setForm({...form,due_date:e.target.value})}/></label><div style={{border:"1px solid #e5e7eb",borderRadius:10,padding:12,display:"grid",gap:10}}><strong>Add inventory items and optional add-ons</strong><div style={{display:"grid",gridTemplateColumns:"minmax(0,1fr) 130px auto",gap:8,alignItems:"end"}}><label>Inventory item / service<select value={addItemId} onChange={e=>setAddItemId(e.target.value)}><option value="">Choose item</option>{catalog.map(i=><option key={i.id} value={i.id}>{i.item_name} · {money(i.sale_price)}</option>)}</select></label><label>Line type<select value={addItemType} onChange={e=>setAddItemType(e.target.value)}><option value="ITEM">Main item</option><option value="ADD_ON">Add-on</option></select></label><button type="button" className="secondary" disabled={!addItemId} onClick={()=>{const item=catalog.find(i=>i.id===addItemId);if(!item)return;const tiers=Array.isArray(item.pricing_tiers)?item.pricing_tiers:[];const price=Number((tiers.find(t=>Number(t.min_quantity)===1)||tiers[0])?.unit_price??item.sale_price??0);setForm(v=>({...v,items:[...v.items,{id:item.id,item_code:item.item_code,item_name:item.item_name,line_type:addItemType,quantity:1,unit_price:price,tax_rate:Number(item.tax_rate??13)}]}));setAddItemId("");}}>Add</button></div>{form.items.length?form.items.map((x,index)=><div key={index} style={{display:"grid",gridTemplateColumns:"minmax(0,1fr) 75px 105px 85px auto",gap:8,alignItems:"end",borderTop:"1px solid #e5e7eb",paddingTop:9}}><div><strong>{x.item_name}</strong><div className="muted">{x.line_type==="ADD_ON"?"Optional add-on":"Main item"} · {x.item_code}</div></div><label>Qty<input type="number" min="1" step="1" value={x.quantity} onChange={e=>setForm(v=>({...v,items:v.items.map((z,i)=>i===index?{...z,quantity:Number(e.target.value)}:z)}))}/></label><label>Unit price<input type="number" min="0" step="0.01" value={x.unit_price} onChange={e=>setForm(v=>({...v,items:v.items.map((z,i)=>i===index?{...z,unit_price:e.target.value}:z)}))}/></label><label>HST %<input type="number" min="0" step="0.01" value={x.tax_rate} onChange={e=>setForm(v=>({...v,items:v.items.map((z,i)=>i===index?{...z,tax_rate:e.target.value}:z)}))}/></label><button type="button" className="secondary" onClick={()=>setForm(v=>({...v,items:v.items.filter((_,i)=>i!==index)}))}>Remove</button></div>):<p className="muted">No items added yet. Choose a product or service above.</p>}<div style={{borderTop:"1px solid #e5e7eb",paddingTop:10,textAlign:"right"}}><div>Subtotal: <strong>{money(form.items.reduce((s,x)=>s+Number(x.quantity||0)*Number(x.unit_price||0),0))}</strong></div><div>HST: <strong>{money(form.items.reduce((s,x)=>s+Number(x.quantity||0)*Number(x.unit_price||0)*Number(x.tax_rate||0)/100,0))}</strong></div><div style={{fontSize:17}}>Total: <strong>{money(form.items.reduce((s,x)=>s+Number(x.quantity||0)*Number(x.unit_price||0)*(1+Number(x.tax_rate||0)/100),0))}</strong></div></div></div><label>Notes<textarea value={form.notes} onChange={e=>setForm({...form,notes:e.target.value})}/></label><div className="notice">E-transfer payment instructions: admin@dvrealty.ca. Include the invoice number in the transfer message.</div><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowCreate(false)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Create invoice"}</button></div></form></div></div>}
  {showPayment&&<div className="overlay"><div className="modal" style={{maxWidth:540}}><div className="modalhead"><h2>Record payment — {showPayment.invoice_number}</h2><button className="iconbtn" onClick={()=>setShowPayment(null)}>×</button></div><form onSubmit={recordPayment} style={{display:"grid",gap:12}}><p>Outstanding balance: <strong>{money(showPayment.balance_amount)}</strong></p><label>Payment amount<input type="number" min="0.01" max={showPayment.balance_amount} step="0.01" required value={paymentForm.amount} onChange={e=>setPaymentForm({...paymentForm,amount:e.target.value})}/></label><label>Payment date<input type="date" required value={paymentForm.payment_date} onChange={e=>setPaymentForm({...paymentForm,payment_date:e.target.value})}/></label><label>Method<select value={paymentForm.method} onChange={e=>setPaymentForm({...paymentForm,method:e.target.value})}><option>E-transfer</option><option>Cheque</option><option>Cash</option><option>Credit card (Square)</option><option>Other</option></select></label><label>Reference number<input value={paymentForm.reference_number} onChange={e=>setPaymentForm({...paymentForm,reference_number:e.target.value})}/></label><label>Notes<textarea value={paymentForm.notes} onChange={e=>setPaymentForm({...paymentForm,notes:e.target.value})}/></label><div style={{display:"flex",justifyContent:"flex-end",gap:8}}><button type="button" className="secondary" onClick={()=>setShowPayment(null)}>Cancel</button><button className="primary" disabled={busy}>{busy?"Saving…":"Save payment"}</button></div></form></div></div>}
 </div>
}
