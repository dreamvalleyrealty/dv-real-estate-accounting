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
 const [settlement,setSettlement]=useState(null),[accounts,setAccounts]=useState([]),[payments,setPayments]=useState([]),[loading,setLoading]=useState(true),[busy,setBusy]=useState(false),[message,setMessage]=useState(""),[error,setError]=useState("");
 const [form,setForm]=useState({real_estate_trust_account_id:"",commission_trust_account_id:"",commission_transfer_date:today(),commission_transfer_reference:""});
 const load=useCallback(async()=>{
  if(!supabase||!transaction?.id){setLoading(false);setError("Supabase is not connected or the transaction is missing.");return}
  setLoading(true);setError("");setMessage("");
  const [s,a,p]=await Promise.all([
   supabase.from("dv_accounting_seller_settlements").select("*").eq("transaction_id",transaction.id).maybeSingle(),
   supabase.from("dv_accounting_bank_accounts").select("*").eq("company_id",transaction.company_id).order("name"),
   supabase.from("dv_accounting_seller_settlement_payments").select("id,transaction_id,company_id,settlement_id,payee_type,status,amount,trust_transaction_id,trust_disbursement_id,direction_storage_path").eq("transaction_id",transaction.id)
  ]);
  if(s.error||a.error||p.error){setError([s.error,a.error,p.error].filter(Boolean).map(x=>x.message).join(" · "));setLoading(false);return}
  setSettlement(s.data||null);setAccounts(a.data||[]);setPayments(p.data||[]);
  if(s.data)setForm({real_estate_trust_account_id:s.data.real_estate_trust_account_id||"",commission_trust_account_id:s.data.commission_trust_account_id||"",commission_transfer_date:s.data.commission_transfer_date||today(),commission_transfer_reference:s.data.commission_transfer_reference||("Commission transfer - "+(transaction.transaction_number||"Trade"))});
  setLoading(false);
 },[transaction?.id,transaction?.company_id,transaction?.transaction_number]);
 useEffect(()=>{load()},[load]);
 const realEstateAccounts=useMemo(()=>accounts.filter(isRE),[accounts]);
 const commissionAccounts=useMemo(()=>accounts.filter(isCT),[accounts]);
 const amount=useMemo(()=>Math.round((Number(settlement?.listing_commission_amount||0)+Number(settlement?.cooperating_commission_amount||0)+Number(settlement?.commission_hst_amount||0))*100)/100,[settlement]);
 const paid=useMemo(()=>payments.filter(p=>p.settlement_id===settlement?.id&&p.transaction_id===transaction?.id&&p.company_id===transaction?.company_id&&String(p.status||"").toUpperCase()==="COMPLETED"&&(!!p.trust_transaction_id||!!p.trust_disbursement_id)&&(["SELLER","LANDLORD"].includes(String(p.payee_type||"").toUpperCase())||!!p.direction_storage_path)).reduce((sum,p)=>sum+Number(p.amount||0),0),[payments,settlement?.id,transaction?.id,transaction?.company_id]);
 const outstandingSeller=Math.max(0,Math.round((Number(settlement?.seller_proceeds_amount||0)-paid)*100)/100);
 const isPosted=postedStatus(settlement?.status);
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
 async function postTransfer(){
  if(!settlement?.id)return setError("A saved Seller / Landlord Settlement record is required before transfer.");
  if(isPosted)return setError("This settlement is already marked ready for Commission Payroll. Check its trust ledger history before attempting another transfer.");\n  if(!settlementReadyForTransfer)return setError("Transfer blocked: save and calculate the Seller / Landlord Settlement first.");
  if(outstandingSeller>0.009)return setError("Transfer blocked: "+money(outstandingSeller)+" in seller/landlord proceeds is still outstanding. Complete and post the seller/landlord payment first.");
  if(!source||!destination||source.id===destination.id)return setError("Select two different valid trust accounts.");
  if(amount<=0)return setError("The saved commission amount must be greater than $0.00.");
  const ref=String(form.commission_transfer_reference||"").trim();
  if(!ref||!form.commission_transfer_date)return setError("Enter and save a transfer date and reference first.");
  if(!window.confirm("Post "+money(amount)+" from Real Estate Trust to Commission Trust for "+(transaction.transaction_number||"this trade")+"? Both trust ledger entries must post together. This does not pay the seller or landlord."))return;
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
    <div><h3 style={{margin:"0 0 6px"}}>Commission Trust Transfer</h3><div style={{fontWeight:700}}>{transaction?.transaction_number||"Trade number pending"} · {address||"Property address unavailable"}</div><div className="muted" style={{marginTop:4}}>Move the brokerage commission from Real Estate Trust to Commission Trust. This action does not pay the seller/landlord and does not run Commission Payroll.</div></div>
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
    <div className="panel" style={{padding:14}}><div className="muted">Commission transfer amount</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(amount)}</div><div className="muted" style={{marginTop:4}}>Listing commission + cooperating commission + HST, from the saved settlement</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Seller / landlord proceeds outstanding</div><div style={{fontSize:24,fontWeight:800,marginTop:4}}>{money(outstandingSeller)}</div><div className="muted" style={{marginTop:4}}>Must be $0.00 before the transfer can post</div></div>
    <div className="panel" style={{padding:14}}><div className="muted">Settlement status</div><div style={{fontSize:18,fontWeight:800,marginTop:4}}>{settlement.status||"—"}</div><div style={{marginTop:6}}>{isPosted?<span className="notice"><ShieldCheck size={15}/> Transfer workflow already marked ready</span>:<span className="muted">Transfer has not been confirmed as posted</span>}</div></div>
   </div>
   <div className="panel" style={{padding:16}}>
    <h3 style={{marginTop:0}}>Transfer details</h3>
    <div className="tx-grid">
     <label>From — Real Estate Trust account<select required value={form.real_estate_trust_account_id} onChange={e=>setForm(v=>({...v,real_estate_trust_account_id:e.target.value}))}><option value="">Select source account</option>{realEstateAccounts.map(a=><option key={a.id} value={a.id}>{a.name}{a.account_number_last4?" · "+a.account_number_last4:""}</option>)}</select></label>
     <label>To — Commission Trust account<select required value={form.commission_trust_account_id} onChange={e=>setForm(v=>({...v,commission_trust_account_id:e.target.value}))}><option value="">Select destination account</option>{commissionAccounts.map(a=><option key={a.id} value={a.id}>{a.name}{a.account_number_last4?" · "+a.account_number_last4:""}</option>)}</select></label>
     <label>Transfer date<input type="date" required value={form.commission_transfer_date} onChange={e=>setForm(v=>({...v,commission_transfer_date:e.target.value}))}/></label>
     <label>Transfer reference<input required value={form.commission_transfer_reference} onChange={e=>setForm(v=>({...v,commission_transfer_reference:e.target.value}))} placeholder="Commission transfer reference"/></label>
    </div>
    <div className="notice" style={{marginTop:14}}><AlertCircle size={16}/> Posting creates matching trust-ledger entries through the existing atomic database function. It will not send a bank payment, pay the seller, or issue commission payroll.</div>
    <div className="modalactions" style={{marginTop:16}}>
     <button type="button" className="secondary" onClick={onClose}>Close</button>
     <button type="button" className="secondary" disabled={busy||isPosted} onClick={saveTransferDetails}><Save size={15}/>{busy?"Saving…":"Save Transfer Details"}</button>
     <button type="button" className="primary" disabled={busy||isPosted||!settlementReadyForTransfer||outstandingSeller>0.009||amount<=0||!source||!destination||source.id===destination.id||!form.commission_transfer_reference.trim()||!form.commission_transfer_date} onClick={postTransfer}><ArrowLeftRight size={15}/>{busy?"Posting…":"Post Trust Transfer"}</button>
    </div>
   </div>
  </>}
 </div>
}
