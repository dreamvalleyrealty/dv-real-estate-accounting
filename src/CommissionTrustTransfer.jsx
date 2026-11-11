import {useCallback,useEffect,useMemo,useState} from "react";
import {AlertCircle,ArrowLeftRight,CheckCircle2,RefreshCw,Save,ShieldCheck} from "lucide-react";
import {supabase} from "./lib/supabase";

const today=()=>new Date().toISOString().slice(0,10);
const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD"}).format(Number(n||0));
const norm=v=>String(v||"").toUpperCase().replace(/[^A-Z]/g,"");
const isRE=a=>norm(a?.account_type)==="REALESTATETRUST"||(/REAL\s*ESTATE\s*TRUST/i.test(String(a?.name||""))&&!/COMMISSION/i.test(String(a?.name||"")));
const isCT=a=>norm(a?.account_type)==="COMMISSIONTRUST"||/COMMISSION\s*TRUST/i.test(String(a?.name||""));
const postedStatus=s=>["READY_FOR_COMMISSION_PAYROLL","COMMISSION_PAYROLL_PROCESSED","PAYMENTS_COMPLETED"].includes(String(s||"").toUpperCase());

export default function CommissionTrustTransfer({transaction,onClose,onOpenSettlement}){
 const [settlement,setSettlement]=useState(null),[accounts,setAccounts]=useState([]),[payments,setPayments]=useState([]),[trustLiabilities,setTrustLiabilities]=useState([]),[trustTransactions,setTrustTransactions]=useState([]),[loading,setLoading]=useState(true),[busy,setBusy]=useState(false),[message,setMessage]=useState(""),[error,setError]=useState("");
 const [form,setForm]=useState({real_estate_trust_account_id:"",commission_trust_account_id:"",commission_transfer_date:today(),commission_transfer_reference:""});
 const [receiptForm,setReceiptForm]=useState({amount:"",payment_date:today(),payment_method:"",payment_reference:"",remitter_name:""});
 const [sellerSolicitor,setSellerSolicitor]=useState(null);
 const load=useCallback(async()=>{
  if(!supabase||!transaction?.id){setLoading(false);setError("Supabase is not connected or the transaction is missing.");return}
  setLoading(true);setError("");setMessage("");
  const [s,a,peopleResult]=await Promise.all([
   supabase.from("dv_accounting_seller_settlements").select("*").eq("transaction_id",transaction.id).maybeSingle(),
   supabase.from("dv_accounting_bank_accounts").select("*").eq("company_id",transaction.company_id).order("name"),
   supabase.from("dv_accounting_transaction_people").select("*").eq("transaction_id",transaction.id)
  ]);
  if(s.error||a.error||peopleResult.error){setError([s.error,a.error,peopleResult.error].filter(Boolean).map(x=>x.message).join(" · "));setLoading(false);return}
  const people=peopleResult.data||[];
  const exactSellerSolicitor=people.find(p=>norm(p.person_type)==="SELLERSOLICITOR");
  const genericSolicitors=people.filter(p=>["SOLICITOR","LAWYER"].includes(norm(p.person_type)));
  const solicitor=exactSellerSolicitor||(genericSolicitors.length===1?genericSolicitors[0]:null);
  if(solicitor){
   let contact=null,firm=null;
   const contactId=solicitor.contact_id||solicitor.existing_contact_id;
   if(contactId){const result=await supabase.from("dv_accounting_contacts").select("*").eq("id",contactId).maybeSingle();if(!result.error)contact=result.data||null;}
   const firmId=contact?.law_firm_id||solicitor.law_firm_id;
   if(firmId){const result=await supabase.from("dv_accounting_law_firms").select("*").eq("id",firmId).maybeSingle();if(!result.error)firm=result.data||null;}
   const pick=(...values)=>values.find(v=>String(v||"").trim())||"";
   const personName=[pick(solicitor.first_name,contact?.first_name),pick(solicitor.last_name,contact?.last_name)].filter(Boolean).join(" ");
   const firmName=pick(solicitor.company_name,solicitor.law_firm,contact?.company_name,firm?.firm_name);
   const remitter=[personName,firmName].filter(Boolean).join(" — ");
   setSellerSolicitor({name:personName,firm:firmName,email:pick(solicitor.email,contact?.email,firm?.billing_email),phone:pick(solicitor.phone,contact?.phone,firm?.phone),address:pick(solicitor.address,contact?.address,firm?.address)});
   setReceiptForm(v=>({...v,remitter_name:v.remitter_name||remitter}));
  }else{setSellerSolicitor(null)}
  const settlementRow=s.data||null;
  let paymentRows=[],liabilityRows=[],trustRows=[];
  if(settlementRow?.id){
   const [p,l,t]=await Promise.all([
    supabase.from("dv_accounting_seller_settlement_payments").select("*").eq("settlement_id",settlementRow.id),
    supabase.from("dv_accounting_trust_liabilities").select("*").eq("transaction_id",transaction.id),
    supabase.from("dv_accounting_trust_transactions").select("*").eq("transaction_id",transaction.id).order("created_at",{ascending:true})
   ]);
   const failed=[p.error,l.error,t.error].filter(Boolean);
   if(failed.length){setError("Could not load settlement funding history: "+failed.map(x=>x.message).join(" · "));setLoading(false);return}
   paymentRows=p.data||[];liabilityRows=l.data||[];trustRows=t.data||[];
  }
  setSettlement(settlementRow);setAccounts(a.data||[]);setPayments(paymentRows);setTrustLiabilities(liabilityRows);setTrustTransactions(trustRows);
  if(s.data)setForm({real_estate_trust_account_id:s.data.real_estate_trust_account_id||"",commission_trust_account_id:s.data.commission_trust_account_id||"",commission_transfer_date:s.data.commission_transfer_date||today(),commission_transfer_reference:s.data.commission_transfer_reference||("Commission transfer - "+(transaction.transaction_number||"Trade"))});
  setLoading(false);
 },[transaction?.id,transaction?.company_id,transaction?.transaction_number]);
 useEffect(()=>{load()},[load]);
 const realEstateAccounts=useMemo(()=>accounts.filter(isRE),[accounts]);
 const commissionAccounts=useMemo(()=>accounts.filter(isCT),[accounts]);
 const amount=useMemo(()=>Math.round((Number(settlement?.listing_commission_amount||0)+Number(settlement?.cooperating_commission_amount||0)+Number(settlement?.commission_hst_amount||0))*100)/100,[settlement]);
 const paid=useMemo(()=>payments.filter(p=>p.settlement_id===settlement?.id&&String(p.status||"").toUpperCase()==="COMPLETED"&&!!p.trust_transaction_id&&(["SELLER","LANDLORD"].includes(String(p.payee_type||"").toUpperCase())||!!p.direction_storage_path)).reduce((sum,p)=>sum+Number(p.amount||0),0),[payments,settlement?.id,transaction?.id,transaction?.company_id]);
 const outstandingSeller=Math.max(0,Math.round((Number(settlement?.seller_proceeds_amount||0)-paid)*100)/100);
 const realEstateFunding=Math.round(trustLiabilities.filter(x=>x.trust_account_type==="REAL_ESTATE_TRUST").reduce((sum,x)=>sum+(x.direction==="RECEIVABLE"?1:-1)*Number(x.amount||0),0)*100)/100;
 const commissionTrustFunding=Math.round(trustLiabilities.filter(x=>x.trust_account_type==="COMMISSION_TRUST").reduce((sum,x)=>sum+(x.direction==="RECEIVABLE"?1:-1)*Number(x.amount||0),0)*100)/100;
 const realEstateTransferRequired=Math.max(0,Math.round((amount-commissionTrustFunding)*100)/100);
 const fundingShortfall=Math.max(0,Math.round((amount-realEstateFunding-commissionTrustFunding)*100)/100);
 const solicitorReceipts=trustTransactions.filter(x=>x.trust_account_type==="COMMISSION_TRUST"&&x.direction==="DEPOSIT"&&x.status==="POSTED"&&String(x.description||"").startsWith("Solicitor direct commission funding received from "));

 const isPosted=postedStatus(settlement?.status);
 useEffect(()=>{if(fundingShortfall>0.009&&(!receiptForm.amount||Number(receiptForm.amount)>fundingShortfall))setReceiptForm(v=>({...v,amount:fundingShortfall.toFixed(2)}))},[fundingShortfall]);
 const settlementReadyForTransfer=["SELLER_PROCEEDS_CALCULATED","SELLER_PAID"].includes(String(settlement?.status||"").toUpperCase());
 const source=realEstateAccounts.find(a=>a.id===form.real_estate_trust_account_id);
 const destination=commissionAccounts.find(a=>a.id===form.commission_trust_account_id);
 async function saveTransferDetails(){
  if(!settlement?.id)return setError("A saved Seller / Landlord Settlement record is required before a commission trust transfer can be posted.");
  if(!source||!destination)return setError("Select a valid Real Estate Trust account and Commission Trust account.");
  if(source.id===destination.id)return setError("Choose two different trust accounts.");
  if(!form.commission_transfer_date||!String(form.commission_transfer_reference||"").trim())return setError("Enter the transfer date and reference.");
  setBusy(true);setError("");setMessage("");
  const {data,error}=await supabase.from("dv_accounting_seller_settlements").update({real_estate_trust_account_id:source.id,commission_trust_account_id:destination.id,commission_transfer_date:form.commission_transfer_date,commission_transfer_reference:String(form.commission_transfer_reference).trim(),updated_at:new Date().toISOString()}).eq("id",settlement.id).select("*").single();
  setBusy(false);if(error){setError("Could not save transfer details: "+error.message);return}
  setSettlement(data);setMessage("Transfer details saved. No money has been moved yet.");
 }
 async function receiveSolicitorFunding(){
  if(!settlement?.id)return setError("Save the Seller / Landlord Settlement before recording solicitor funds.");
  if(isPosted)return setError("This settlement has already been transferred to Commission Payroll.");
  if(fundingShortfall<=0.009)return setError("There is no remaining commission funding shortfall.");
  const amountToReceive=Number(receiptForm.amount||0);
  if(amountToReceive<=0)return setError("Enter the solicitor deposit amount.");
  if(amountToReceive>fundingShortfall+0.005)return setError("The deposit cannot exceed the remaining commission funding shortfall of "+money(fundingShortfall)+".");
  if(!receiptForm.payment_date||!receiptForm.payment_method||!receiptForm.payment_reference.trim()||!receiptForm.remitter_name.trim())return setError("Enter the deposit date, payment method, cheque number or EFT reference, and solicitor/remitter.");
  setBusy(true);setError("");setMessage("");
  const {data,error}=await supabase.rpc("dv_accounting_receive_solicitor_commission_funding",{
   p_settlement_id:settlement.id,p_amount:amountToReceive,p_payment_date:receiptForm.payment_date,
   p_payment_reference:receiptForm.payment_method+": "+receiptForm.payment_reference.trim(),p_remitter_name:receiptForm.remitter_name.trim()
  });
  setBusy(false);
  if(error){setError("Could not record solicitor commission deposit: "+error.message);return}
  setMessage(data?.duplicate?"This solicitor deposit was already recorded. No duplicate receipt was created.":"Solicitor deposit recorded in Commission Trust and linked to this trade.");
  setReceiptForm(v=>({...v,amount:"",payment_reference:""}));
  await load();
 }
 async function postTransfer(){
  if(!settlement?.id)return setError("A saved Seller / Landlord Settlement record is required before transfer.");
  if(isPosted)return setError("This settlement is already marked ready for Commission Payroll. Check its trust ledger history before attempting another transfer.");
  if(!settlementReadyForTransfer)return setError("Transfer blocked: save and calculate the Seller / Landlord Settlement first.");
  if(outstandingSeller>0.009)return setError("Transfer blocked: "+money(outstandingSeller)+" in seller/landlord proceeds is still outstanding. Complete and post the seller/landlord payment first.");
  if(fundingShortfall>0.009)return setError("Transfer blocked: commission funding is short by "+money(fundingShortfall)+". Record the seller solicitor deposit into Commission Trust first.");
  if(!source||!destination||source.id===destination.id)return setError("Select two different valid trust accounts.");
  if(amount<=0)return setError("The saved commission amount must be greater than $0.00.");
  const ref=String(form.commission_transfer_reference||"").trim();
  if(!ref||!form.commission_transfer_date)return setError("Enter and save a transfer date and reference first.");
  if(!window.confirm("Complete commission funding of "+money(amount)+" for "+(transaction.transaction_number||"this trade")+"? The system will transfer "+money(realEstateTransferRequired)+" from Real Estate Trust and count "+money(commissionTrustFunding)+" already received directly into Commission Trust. This does not pay the seller or landlord."))return;
  setBusy(true);setError("");setMessage("");
  const {data,error}=await supabase.rpc("dv_accounting_process_seller_commission_transfer",{p_settlement_id:settlement.id,p_transfer_reference:ref,p_transfer_date:form.commission_transfer_date});
  setBusy(false);
  if(error){setError("Transfer was not confirmed: "+error.message);return}
  setSettlement(data||settlement);setMessage("Trust transfer posted successfully. Verify the matching debit and credit in the trust ledgers.");
  await load();
 }
 const address=transaction?.property_address||[transaction?.street_number,transaction?.street_name].filter(Boolean).join(" ");
 return <div className="tx-section" style={{padding:18,overflowY:"auto"}}>
  <div className="panel" style={{padding:16,marginBottom:16}}>
   <div style={{display:"flex",gap:12,alignItems:"flex-start",justifyContent:"space-between",flexWrap:"wrap"}}>
    <div><h3 style={{margin:"0 0 6px"}}>Commission Trust Transfer</h3><div style={{fontWeight:700}}>{transaction?.transaction_number||"Trade number pending"} · {address||"Property address unavailable"}</div><div className="muted" style={{marginTop:4}}>Fund the brokerage commission using the Real Estate Trust balance and, where needed, a direct deposit from the seller’s solicitor into Commission Trust. This does not pay the seller/landlord or run Commission Payroll.</div></div>
    <button type="button" className="secondary" onClick={load} disabled={loading||busy}><RefreshCw size={15}/> Refresh</button>
   </div>
  </div>
  {error&&<div className="error" role="alert" style={{marginBottom:12}}>{error}</div>}
  {message&&<div className="notice" role="status" style={{marginBottom:12}}><CheckCircle2 size={16}/>{message}</div>}
  {loading?<p>Loading transaction and trust details…</p>:!settlement?<div className="panel" style={{padding:16}}>
   <h3>Settlement record required</h3><p>This transaction does not have a saved Seller / Landlord Settlement record yet. The commission transfer has its own screen, but the accounting engine requires the settlement record and the seller/landlord proceeds to be accounted for before it can post.</p>
   <div style={{display:"flex",gap:8,flexWrap:"wrap"}}><button type="button" className="primary" onClick={()=>{onClose?.();onOpenSettlement?.(transaction)}}>Open settlement setup</button><button type="button" className="secondary" onClick={onClose}>Close</button></div>
  </div>:<>
   <div className="tx-grid" style={{marginBottom:14}}>
    <div className="panel" style={{padding:14}}><div className="muted">Total commission funding required</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(amount)}</div><div className="muted" style={{marginTop:4}}>Listing + cooperating commission + HST</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Real Estate Trust funds available</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(realEstateFunding)}</div><div className="muted" style={{marginTop:4}}>Trade-linked posted trust liability</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Direct solicitor funds in Commission Trust</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(commissionTrustFunding)}</div><div className="muted" style={{marginTop:4}}>Posted Commission Trust deposits linked to this trade</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Funding shortfall</div><div style={{fontSize:24,fontWeight:800,marginTop:4,color:fundingShortfall>0.009?"#b42318":"#067647"}}>{money(fundingShortfall)}</div><div className="muted" style={{marginTop:4}}>{fundingShortfall>0.009?"Seller solicitor deposit required":"Commission fully funded"}</div></div>
   </div>
   <div className="tx-grid" style={{marginBottom:14}}>
    <div className="panel" style={{padding:14}}><div className="muted">Seller / landlord proceeds outstanding</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(outstandingSeller)}</div><div className="muted" style={{marginTop:4}}>Must be $0.00 before Commission Payroll</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Settlement status</div><div style={{fontSize:18,fontWeight:800,marginTop:4}}>{settlement.status||"—"}</div><div style={{marginTop:6}}>{isPosted?<span className="notice"><ShieldCheck size={15}/> Commission funding posted</span>:<span className="muted">Commission transfer has not been confirmed as posted</span>}</div></div>
   </div>
   {fundingShortfall>0.009&&!isPosted&&<div className="panel" style={{padding:16,marginBottom:14,borderColor:"#d6b36a"}}>
    <h3 style={{marginTop:0}}>Additional commission funds from seller’s solicitor</h3>
    <p className="muted">Use this when the seller’s solicitor sends the commission shortfall directly to Dream Valley’s Commission Trust account. The receipt is recorded separately from the Real Estate Trust transfer and linked to this trade.</p>
    <div className="tx-grid">
     <label>Amount received<input type="number" min="0.01" max={fundingShortfall.toFixed(2)} step="0.01" value={receiptForm.amount} onChange={e=>setReceiptForm(v=>({...v,amount:e.target.value}))}/><small className="muted">Maximum remaining shortfall: {money(fundingShortfall)}</small></label>
     <label>Deposit date<input type="date" value={receiptForm.payment_date} onChange={e=>setReceiptForm(v=>({...v,payment_date:e.target.value}))}/></label>
     <label>Seller’s solicitor / law firm<input value={receiptForm.remitter_name} onChange={e=>setReceiptForm(v=>({...v,remitter_name:e.target.value}))} placeholder="Pulled from the trade People tab"/>{sellerSolicitor&&<small className="muted" style={{display:"block",marginTop:4}}>{[sellerSolicitor.email,sellerSolicitor.phone,sellerSolicitor.address].filter(Boolean).join(" · ")}</small>}</label>
     <label>Payment method<select value={receiptForm.payment_method} onChange={e=>setReceiptForm(v=>({...v,payment_method:e.target.value,payment_reference:""}))}><option value="">Select payment method</option><option value="CHEQUE">Cheque</option><option value="EFT">EFT</option></select></label>
     <label>{receiptForm.payment_method==="CHEQUE"?"Cheque number":receiptForm.payment_method==="EFT"?"EFT / bank deposit reference":"Cheque number or EFT reference"}<input value={receiptForm.payment_reference} onChange={e=>setReceiptForm(v=>({...v,payment_reference:e.target.value}))} placeholder={receiptForm.payment_method==="CHEQUE"?"Enter cheque number":receiptForm.payment_method==="EFT"?"Enter EFT confirmation / bank reference":"Select cheque or EFT first"}/></label>
    </div>
    <div className="modalactions" style={{marginTop:14}}><button type="button" className="primary" disabled={busy||!receiptForm.amount||Number(receiptForm.amount)<=0||Number(receiptForm.amount)>fundingShortfall+0.005||!receiptForm.payment_reference.trim()||!receiptForm.remitter_name.trim()} onClick={receiveSolicitorFunding}><Save size={15}/>{busy?"Recording…":"Record Solicitor Deposit"}</button></div>
   </div>}
   {solicitorReceipts.length>0&&<div className="panel" style={{padding:16,marginBottom:14}}>
    <h3 style={{marginTop:0}}>Solicitor commission deposits recorded</h3>
    <div className="tablewrap"><table><thead><tr><th>Deposit date</th><th>Remitter</th><th>Method</th><th>Reference</th><th>Amount</th><th>Status</th></tr></thead><tbody>{solicitorReceipts.map(x=><tr key={x.id}><td>{x.ledger_date}</td><td>{String(x.description||"").replace(/^Solicitor direct commission funding received from /,"").replace(" - "+(settlement.matter||""),"")}</td><td>{String(x.reference||"").split(":")[0]||"—"}</td><td>{String(x.reference||"").replace(/^[^:]+:\s*/,"")||"—"}</td><td>{money(x.amount)}</td><td>{x.status}</td></tr>)}</tbody></table></div>
   </div>}
   <div className="panel" style={{padding:16}}>
    <h3 style={{marginTop:0}}>Transfer details</h3>
    <div className="tx-grid">
     <label>From — Real Estate Trust account<select required value={form.real_estate_trust_account_id} onChange={e=>setForm(v=>({...v,real_estate_trust_account_id:e.target.value}))}><option value="">Select source account</option>{realEstateAccounts.map(a=><option key={a.id} value={a.id}>{a.name}{a.account_number_last4?" · "+a.account_number_last4:""}</option>)}</select></label>
     <label>To — Commission Trust account<select required value={form.commission_trust_account_id} onChange={e=>setForm(v=>({...v,commission_trust_account_id:e.target.value}))}><option value="">Select destination account</option>{commissionAccounts.map(a=><option key={a.id} value={a.id}>{a.name}{a.account_number_last4?" · "+a.account_number_last4:""}</option>)}</select></label>
     <label>Transfer date<input type="date" required value={form.commission_transfer_date} onChange={e=>setForm(v=>({...v,commission_transfer_date:e.target.value}))}/></label>
     <label>Transfer reference<input required value={form.commission_transfer_reference} onChange={e=>setForm(v=>({...v,commission_transfer_reference:e.target.value}))} placeholder="Commission transfer reference"/></label>
    </div>
    <div className="notice" style={{marginTop:14}}><AlertCircle size={16}/> Expected Real Estate Trust transfer: {money(realEstateTransferRequired)}. The system counts solicitor deposits already received in Commission Trust and posts only the remaining transfer. It does not send a bank payment, pay the seller, or issue Commission Payroll.</div>
    <div className="modalactions" style={{marginTop:16}}>
     <button type="button" className="secondary" onClick={onClose}>Close</button>
     <button type="button" className="secondary" disabled={busy||isPosted} onClick={saveTransferDetails}><Save size={15}/>{busy?"Saving…":"Save Transfer Details"}</button>
     <button type="button" className="primary" disabled={busy||isPosted||!settlementReadyForTransfer||outstandingSeller>0.009||fundingShortfall>0.009||amount<=0||!source||!destination||source.id===destination.id||!form.commission_transfer_reference.trim()||!form.commission_transfer_date} onClick={postTransfer}><ArrowLeftRight size={15}/>{busy?"Posting…":"Post Trust Transfer"}</button>
    </div>
   </div>
  </>}
 </div>
}
