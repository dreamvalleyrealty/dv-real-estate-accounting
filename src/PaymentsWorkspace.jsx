import {useEffect,useMemo,useState} from "react";
import {AlertCircle,CheckCircle2,Clock3,CreditCard,ExternalLink,FileText,Landmark,RefreshCw,Search,Users,Wallet} from "lucide-react";
import {supabase} from "./lib/supabase";

const money=value=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD",minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(value||0));
const clean=value=>String(value??"").trim();
const upper=value=>clean(value).toUpperCase();
const shortDate=value=>{if(!value)return "—";const d=new Date(String(value).slice(0,10)+"T12:00:00");return Number.isNaN(d.getTime())?String(value):d.toLocaleDateString("en-CA",{year:"numeric",month:"short",day:"numeric"})};
const today=()=>{const d=new Date();return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")};
const completeStates=["PAID","COMPLETED","ISSUED","POSTED","CLOSED"];
const attentionStates=["RETURNED","REJECTED","FAILED","VOID","VOIDED","OVERDUE","CANCELLED"];
function stateGroup(status,dueDate){
 const s=upper(status);
 if(completeStates.includes(s))return "COMPLETED";
 if(attentionStates.includes(s)||(dueDate&&String(dueDate).slice(0,10)<today()))return "ATTENTION";
 return "OPEN";
}
function displayState(status){
 const value=clean(status);
 if(!value)return "Status unavailable";
 return value.toLowerCase().split(/[_\s]+/).map(x=>x?x[0].toUpperCase()+x.slice(1):"").join(" ");
}
function record(table,category,title,subtitle,status,date,amount,amountLabel,target,searchExtra=""){
 return {id:table+"-"+Math.random().toString(36).slice(2),category,title,subtitle,status:displayState(status),group:stateGroup(status),date,amount,amountLabel,target,search:[category,title,subtitle,status,date,searchExtra].join(" ").toLowerCase()};
}
const emptyResult=()=>({rows:[],error:""});

export default function PaymentsWorkspace({role="",permissions={},setActive}){
 const isSuperAdmin=upper(role)==="SUPERADMIN";
 const can=code=>isSuperAdmin||!!permissions[code]?.allowed;
 const canCommission=can("commission.view")||can("commission.issue");
 const canBanking=can("banking.view");
 const canExpenses=can("expenses.view");
 const [snapshot,setSnapshot]=useState({commissions:emptyResult(),cheques:emptyResult(),batches:emptyResult(),settlements:emptyResult(),sellerPayments:emptyResult(),expenses:emptyResult(),agentInvoices:emptyResult(),transactions:[],agents:[]});
 const [loading,setLoading]=useState(true);
 const [refreshing,setRefreshing]=useState(false);
 const [lastUpdated,setLastUpdated]=useState(null);
 const [query,setQuery]=useState("");
 const [category,setCategory]=useState("ALL");
 const [statusFilter,setStatusFilter]=useState("ALL");

 async function fetchRows(table,columns,orderColumn,configure){
  if(!supabase)return {rows:[],error:"Database connection is unavailable."};
  let request=supabase.from(table).select(columns);
  if(configure)request=configure(request);
  if(orderColumn)request=request.order(orderColumn,{ascending:false});
  request=request.limit(250);
  const {data,error}=await request;
  return {rows:data||[],error:error?.message||""};
 }

 async function load(background=false){
  if(!supabase){setLoading(false);return}
  if(background)setRefreshing(true);else setLoading(true);
  const needsTradeLookups=canCommission||canBanking;
  const tasks={
   commissions:canCommission?fetchRows("dv_accounting_commissions","id,transaction_id,agent_id,status,gross_commission,paid_date","paid_date"):Promise.resolve(emptyResult()),
   cheques:canCommission?fetchRows("dv_accounting_commission_cheques","commission_id,cheque_date,status,net_amount,payment_method,payment_reference,cheque_number","cheque_date"):Promise.resolve(emptyResult()),
   batches:canBanking?fetchRows("dv_accounting_brokerage_payment_batches","id,payment_date,payment_reference,total_amount,trade_count,status,created_at","payment_date"):Promise.resolve(emptyResult()),
   settlements:canBanking?fetchRows("dv_accounting_seller_settlements","id,transaction_id,status,seller_client_name,matter,seller_proceeds_amount,seller_paid_amount,seller_payment_status,commission_transfer_amount,commission_transfer_reference,commission_transfer_date,updated_at","updated_at"):Promise.resolve(emptyResult()),
   sellerPayments:canBanking?fetchRows("dv_accounting_seller_settlement_payments","id,settlement_id,transaction_id,payee_name,payee_type,amount,payment_date,payment_method,reference,status,trust_transaction_id,created_at","created_at"):Promise.resolve(emptyResult()),
   expenses:canExpenses?fetchRows("dv_accounting_expenses","id,vendor,invoice_number,expense_date,due_date,description,amount,hst_amount,total_amount,status,payment_status,approval_status,posted_at,voided_at","expense_date"):Promise.resolve(emptyResult()),
   agentInvoices:canExpenses?fetchRows("dv_agent_invoices","id,agent_id,invoice_number,due_date,description,total_amount,paid_amount,balance_amount,status,created_at,archived_at","created_at",q=>q.is("archived_at",null)):Promise.resolve(emptyResult())
  };
  if(needsTradeLookups){
   tasks.transactions=fetchRows("dv_accounting_transactions","id,transaction_number,trade_number,property_address","transaction_date");
   tasks.agents=fetchRows("dv_accounting_agents","id,name,first_name,last_name","created_at");
  }
  const entries=await Promise.all(Object.entries(tasks).map(async([key,promise])=>[key,await promise]));
  const next={commissions:emptyResult(),cheques:emptyResult(),batches:emptyResult(),settlements:emptyResult(),sellerPayments:emptyResult(),expenses:emptyResult(),agentInvoices:emptyResult(),transactions:[],agents:[]};
  for(const [key,value] of entries){
   if(key==="transactions"||key==="agents")next[key]=value.rows||[];
   else next[key]=value;
  }
  setSnapshot(next);
  setLastUpdated(new Date());
  setLoading(false);
  setRefreshing(false);
 }

 useEffect(()=>{load(false);const timer=setInterval(()=>{if(typeof document!=="undefined"&&document.visibilityState==="visible")load(true)},60000);return()=>clearInterval(timer)},[role,permissions]);
 const transactionMap=useMemo(()=>new Map(snapshot.transactions.map(x=>[x.id,x])),[snapshot.transactions]);
 const agentMap=useMemo(()=>new Map(snapshot.agents.map(x=>[x.id,x])),[snapshot.agents]);

 const categories=useMemo(()=>[
  {id:"COMMISSIONS",label:"Agent Commissions",description:"Unpaid and issued agent commission records",icon:Users,target:"Commission Payroll",enabled:canCommission,source:"commissions"},
  {id:"BROKERAGE",label:"Other Brokerages",description:"Co-operating brokerage bulk payment batches",icon:BuildingIcon,target:"Commission Payroll",enabled:canBanking,source:"batches"},
  {id:"SELLER",label:"Seller / Landlord",description:"Settlement payments and trust posting status",icon:Landmark,target:"Seller Settlements",enabled:canBanking,source:"sellerPayments"},
  {id:"EXPENSES",label:"Vendors & Expenses",description:"Vendor invoices, approvals and payment status",icon:FileText,target:"Expenses & A/P",enabled:canExpenses,source:"expenses"},
  {id:"AGENT_INVOICES",label:"Agent Invoices",description:"Agent invoice balances and payment status",icon:Wallet,target:"Agent Invoices",enabled:canExpenses,source:"agentInvoices"},
  {id:"TRUST",label:"Trust & Banking",description:"Trust accounts, transfers and bank reconciliation",icon:CreditCard,target:"Banking & Reconciliation",enabled:canBanking,source:null}
 ],[canCommission,canBanking,canExpenses]);

 const items=useMemo(()=>{
  const out=[];
  for(const c of snapshot.commissions.rows){
   const tx=transactionMap.get(c.transaction_id),agent=agentMap.get(c.agent_id);
   const name=agent?.name||[agent?.first_name,agent?.last_name].filter(Boolean).join(" ")||"Agent";
   const status=upper(c.status)||"PENDING";
   const cheque=snapshot.cheques.rows.find(x=>x.commission_id===c.id&&upper(x.status)==="ISSUED");
   const trade=tx?.transaction_number||tx?.trade_number||"Trade not linked";
   out.push(record("commission","COMMISSIONS",name,trade+" · "+(tx?.property_address||"Property unavailable"),status,cheque?.cheque_date||c.paid_date,c.gross_commission,"GCI", "Commission Payroll",tx?.property_address));
  }
  for(const b of snapshot.batches.rows){
   out.push(record("brokerage-batch","BROKERAGE","Brokerage bulk payment",String(b.trade_count||0)+" trades · "+(b.payment_reference||"No reference"),b.status,b.payment_date,b.total_amount,"Batch total","Commission Payroll",b.payment_reference));
  }
  const paymentsBySettlement=new Map();
  for(const p of snapshot.sellerPayments.rows){const list=paymentsBySettlement.get(p.settlement_id)||[];list.push(p);paymentsBySettlement.set(p.settlement_id,list)}
  for(const s of snapshot.settlements.rows){
   const tx=transactionMap.get(s.transaction_id),linked=paymentsBySettlement.get(s.id)||[];
   const trade=tx?.transaction_number||tx?.trade_number||s.matter||"Trade not linked";
   if(linked.length){
    for(const p of linked){
     out.push(record("seller-payment","SELLER",p.payee_name||s.seller_client_name||"Seller / Landlord",trade+" · "+(tx?.property_address||"Property unavailable")+" · "+(p.payment_method||"Payment method not set"),p.status,p.payment_date,p.amount,"Payment amount","Seller Settlements",p.reference));
    }
   }else{
    const status=s.seller_payment_status||s.status||"OPEN";
    out.push(record("seller-settlement","SELLER",s.seller_client_name||"Seller / Landlord",trade+" · "+(tx?.property_address||"Property unavailable")+" · Settlement record",status,s.updated_at,s.seller_proceeds_amount,"Settlement proceeds","Seller Settlements",s.matter));
   }
  }
  for(const e of snapshot.expenses.rows){
   const status=e.voided_at?"VOIDED":(upper(e.approval_status)&&upper(e.approval_status)!=="APPROVED"?e.approval_status:(e.payment_status||e.status||"UNPAID"));
   const amount=e.total_amount??(Number(e.amount||0)+Number(e.hst_amount||0));
   out.push(record("vendor-expense","EXPENSES",e.vendor||"Vendor",[(e.invoice_number?"Invoice "+e.invoice_number:"Invoice number unavailable"),e.description].filter(Boolean).join(" · "),status,e.due_date||e.expense_date,amount,"Invoice total","Expenses & A/P",e.category));
  }
  for(const inv of snapshot.agentInvoices.rows){
   const agent=agentMap.get(inv.agent_id),name=agent?.name||[agent?.first_name,agent?.last_name].filter(Boolean).join(" ")||"Agent";
   out.push(record("agent-invoice","AGENT_INVOICES",name,"Invoice "+(inv.invoice_number||"—")+" · "+(inv.description||""),inv.status,inv.due_date,inv.balance_amount,"Outstanding balance","Agent Invoices"));
  }
  return out.sort((a,b)=>String(b.date||"").localeCompare(String(a.date||"")));
 },[snapshot,transactionMap,agentMap]);

 const visibleItems=useMemo(()=>{
  const needle=query.trim().toLowerCase();
  return items.filter(item=>(category==="ALL"||item.category===category)&&(statusFilter==="ALL"||item.group===statusFilter)&&(!needle||item.search.includes(needle)));
 },[items,query,category,statusFilter]);
 const openCount=items.filter(x=>x.group==="OPEN").length;
 const completedCount=items.filter(x=>x.group==="COMPLETED").length;
 const attentionCount=items.filter(x=>x.group==="ATTENTION").length;
 const errors=categories.filter(c=>c.enabled&&c.source&&snapshot[c.source]?.error);
 const go=target=>{if(typeof setActive==="function")setActive(target)};

 return <div className="payments-workspace">
  <style>{".payments-workspace{display:flex;flex-direction:column;gap:14px;color:#172b4d}.payments-workspace .pagehead{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;flex-wrap:wrap}.payments-workspace .pagehead h1{margin:0;font-size:25px;color:#0f2141}.payments-workspace .pagehead p{margin:5px 0 0;color:#667085;font-size:13px}.payments-workspace .payments-summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}.payments-workspace .summary-card,.payments-workspace .category-card{background:#fff;border:1px solid #e4e7ec;border-radius:11px;padding:14px;min-width:0}.payments-workspace .summary-label{font-size:12px;color:#667085}.payments-workspace .summary-value{font-size:25px;font-weight:750;color:#0f2141;margin-top:4px}.payments-workspace .category-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}.payments-workspace .category-card{display:flex;flex-direction:column;gap:9px;text-align:left;cursor:pointer;transition:border-color .15s,box-shadow .15s}.payments-workspace .category-card:hover{border-color:#9e8556;box-shadow:0 2px 8px rgba(15,33,65,.07)}.payments-workspace .category-top{display:flex;align-items:center;justify-content:space-between;gap:8px}.payments-workspace .category-top svg{color:#9e8556}.payments-workspace .category-card strong{font-size:14px;color:#0f2141}.payments-workspace .category-card small{font-size:12px;color:#667085;line-height:1.45}.payments-workspace .category-count{font-size:12px;color:#344054;font-weight:650}.payments-workspace .payments-panel{background:#fff;border:1px solid #e4e7ec;border-radius:11px;padding:15px;min-width:0}.payments-workspace .payments-toolbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:12px}.payments-workspace .payments-search{display:flex;align-items:center;gap:8px;flex:1 1 260px;min-width:220px;border:1px solid #d0d5dd;border-radius:7px;padding:0 10px;background:#fff}.payments-workspace .payments-search svg{color:#667085;flex:none}.payments-workspace .payments-search input{border:0;outline:0;box-shadow:none;width:100%;min-width:0;padding:10px 0;background:transparent}.payments-workspace .payments-toolbar select{min-width:145px;border:1px solid #d0d5dd;border-radius:7px;padding:9px;background:#fff;color:#344054}.payments-workspace .payments-table-wrap{overflow:auto}.payments-workspace table{width:100%;border-collapse:collapse;min-width:760px;font-size:12px}.payments-workspace th{text-align:left;background:#f8f9fb;color:#475467;font-weight:700;white-space:nowrap}.payments-workspace th,.payments-workspace td{padding:10px 9px;border-bottom:1px solid #eaecf0;vertical-align:middle}.payments-workspace td strong{color:#0f2141}.payments-workspace .status-pill{display:inline-flex;padding:4px 8px;border-radius:20px;background:#f2f4f7;color:#344054;font-size:11px;font-weight:650;white-space:nowrap}.payments-workspace .status-pill.completed{background:#ecfdf3;color:#027a48}.payments-workspace .status-pill.attention{background:#fff4ed;color:#b54708}.payments-workspace .payments-empty{padding:28px 12px;text-align:center;color:#667085;font-size:13px}.payments-workspace .payments-error{border:1px solid #fecdca;background:#fff6f5;color:#b42318;padding:10px 12px;border-radius:8px;font-size:12px}.payments-workspace .muted{color:#667085}.payments-workspace .secondary{display:inline-flex;align-items:center;gap:6px}.payments-workspace .open-link{border:0;background:transparent;color:#0f2141;font-weight:700;cursor:pointer;padding:4px}.payments-workspace .open-link:hover{color:#9e8556;text-decoration:underline}@media(max-width:900px){.payments-workspace .category-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:620px){.payments-workspace .payments-summary{grid-template-columns:repeat(3,minmax(0,1fr));gap:6px}.payments-workspace .summary-card{padding:10px}.payments-workspace .summary-value{font-size:20px}.payments-workspace .category-grid{grid-template-columns:1fr}.payments-workspace .payments-panel{padding:11px}.payments-workspace .payments-search{min-width:100%}.payments-workspace .payments-toolbar select{flex:1}}"} </style>
  <div className="pagehead">
   <div><h1>Payments</h1><p>One place to review payment work across the brokerage. Payment posting remains in each existing accounting workflow.</p></div>
   <div className="actions"><span className="muted" style={{fontSize:11,alignSelf:"center"}}>{lastUpdated?"Updated "+lastUpdated.toLocaleTimeString("en-CA",{hour:"2-digit",minute:"2-digit"}):" "}</span><button type="button" className="secondary" onClick={()=>load(true)} disabled={loading||refreshing}><RefreshCw size={15}/> {refreshing?"Refreshing…":"Refresh"}</button></div>
  </div>
  <div className="payments-summary">
   <div className="summary-card"><div className="summary-label">Open records</div><div className="summary-value">{loading?"—":openCount}</div></div>
   <div className="summary-card"><div className="summary-label">Completed records</div><div className="summary-value">{loading?"—":completedCount}</div></div>
   <div className="summary-card"><div className="summary-label">Needs attention</div><div className="summary-value">{loading?"—":attentionCount}</div></div>
  </div>
  <div className="category-grid">
   {categories.filter(c=>c.enabled).map(c=>{
    const Icon=c.icon,source=c.source,rows=source?snapshot[source].rows:[],count=source?rows.length:"";
    const categoryOpen=items.filter(x=>x.category===c.id&&x.group==="OPEN").length;
    const categoryCompleted=items.filter(x=>x.category===c.id&&x.group==="COMPLETED").length;
    return <button type="button" className="category-card" key={c.id} onClick={()=>{if(c.source)setCategory(c.id);go(c.target)}}>
     <div className="category-top"><Icon size={20}/><ExternalLink size={14}/></div>
     <strong>{c.label}</strong><small>{c.description}</small>
     <div className="category-count">{source?(loading?"Loading…":(count+" records · "+categoryOpen+" open · "+categoryCompleted+" completed")):"Open banking workspace"}</div>
    </button>
   })}
  </div>
  <section className="payments-panel">
   <div style={{display:"flex",alignItems:"center",justifyContent:"space-between",gap:10,flexWrap:"wrap",marginBottom:10}}>
    <div><strong style={{color:"#0f2141"}}>Payment overview</strong><div className="muted" style={{fontSize:11,marginTop:3}}>Read-only view of existing records. Select Open to continue in the original payment screen.</div></div>
    <span className="muted" style={{fontSize:11}}>{visibleItems.length} records shown</span>
   </div>
   <div className="payments-toolbar">
    <label className="payments-search"><Search size={16}/><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search payee, agent, trade, invoice or reference"/></label>
    <select value={category} onChange={e=>setCategory(e.target.value)} aria-label="Filter payment category"><option value="ALL">All categories</option>{categories.filter(c=>c.enabled&&c.source).map(c=><option key={c.id} value={c.id}>{c.label}</option>)}</select>
    <select value={statusFilter} onChange={e=>setStatusFilter(e.target.value)} aria-label="Filter payment status"><option value="ALL">All statuses</option><option value="OPEN">Open</option><option value="COMPLETED">Completed</option><option value="ATTENTION">Needs attention</option></select>
   </div>
   {errors.map(c=><div className="payments-error" key={c.id}><AlertCircle size={14} style={{verticalAlign:"middle",marginRight:5}}/>Could not load {c.label.toLowerCase()}: {snapshot[c.source].error}</div>)}
   <div className="payments-table-wrap">
    <table><thead><tr><th>Category</th><th>Payee / Record</th><th>Trade / Invoice / Reference</th><th>Date</th><th>Amount reference</th><th>Status</th><th></th></tr></thead>
     <tbody>
      {visibleItems.map(item=><tr key={item.id}>
       <td>{categories.find(c=>c.id===item.category)?.label||item.category}</td>
       <td><strong>{item.title}</strong></td>
       <td>{item.subtitle||"—"}</td>
       <td>{shortDate(item.date)}</td>
       <td>{item.amount===null||item.amount===undefined?"—":money(item.amount)}{item.amountLabel?<div className="muted" style={{fontSize:10}}>{item.amountLabel}</div>:null}</td>
       <td><span className={"status-pill "+(item.group==="COMPLETED"?"completed":item.group==="ATTENTION"?"attention":"")}>{item.status}</span></td>
       <td><button type="button" className="open-link" onClick={()=>go(item.target)}>Open</button></td>
      </tr>)}
      {!visibleItems.length&&<tr><td colSpan="7"><div className="payments-empty">{loading?"Loading payment records…":items.length?"No records match these filters.":"No payment records were returned for the sections you can access."}</div></td></tr>}
     </tbody>
    </table>
   </div>
   <div className="muted" style={{fontSize:10,marginTop:9}}>Showing up to the 250 most recent records per category. Amounts are labelled by source record and are not combined into a single payable total.</div>
  </section>
 </div>;
}

function BuildingIcon(props){return <Landmark {...props}/>;}
