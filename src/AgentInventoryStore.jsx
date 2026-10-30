import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "./lib/supabase";
import { ShoppingCart, Package, ClipboardList, RefreshCw, Plus, Minus, CreditCard, HandCoins, CalendarDays } from "lucide-react";

const money=n=>new Intl.NumberFormat("en-CA",{style:"currency",currency:"CAD",minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(n||0));
const dateNow=()=>new Date().toISOString().slice(0,10);
const navy="#0f2141",gold="#9e8556";

export default function AgentInventoryStore({user,agentId}){
 const [items,setItems]=useState([]),[branches,setBranches]=useState([]),[branchId,setBranchId]=useState(""),[stock,setStock]=useState([]),[cart,setCart]=useState({}),[borrowCart,setBorrowCart]=useState({}),[tab,setTab]=useState("SHOP"),[orders,setOrders]=useState([]),[requests,setRequests]=useState([]),[pickup,setPickup]=useState(dateNow()),[due,setDue]=useState(""),[notes,setNotes]=useState(""),[payment,setPayment]=useState("SQUARE"),[busy,setBusy]=useState(false),[error,setError]=useState(""),[message,setMessage]=useState("");
 const load=useCallback(async()=>{
  if(!supabase)return;
  const [i,b,s,o,r,a]=await Promise.all([
   supabase.from("dv_accounting_inventory_items").select("*").eq("is_active",true).order("item_name"),
   supabase.from("dv_accounting_branches").select("id,name").eq("active",true).order("name"),
   supabase.from("dv_accounting_inventory_branch_stock").select("*"),
   supabase.from("dv_accounting_inventory_orders").select("*,items:dv_accounting_inventory_order_items(*)").order("created_at",{ascending:false}).limit(50),
   supabase.from("dv_accounting_inventory_borrow_requests").select("*,items:dv_accounting_inventory_borrow_request_items(*)").order("created_at",{ascending:false}).limit(50),
   supabase.from("dv_accounting_agents").select("branch_id").eq("id",agentId).maybeSingle()
  ]);
  const bad=[i,b,s,o,r,a].find(x=>x.error);if(bad)throw bad.error;
  setItems(i.data||[]);setBranches(b.data||[]);setStock(s.data||[]);setOrders(o.data||[]);setRequests(r.data||[]);
  setBranchId(v=>v||a.data?.branch_id||((b.data||[]).find(x=>x.id)?.id)||"");
 },[]);
 useEffect(()=>{load().catch(e=>setError(e.message))},[load]);
 const available=item=>{const row=stock.find(x=>x.item_id===item.id&&x.branch_id===branchId);return Number(row?row.quantity:item.stock_quantity||0)};
 const shopItems=useMemo(()=>items.filter(i=>["SELLABLE","SERVICE","GIFT"].includes(i.item_type)),[items]);
 const borrowItems=useMemo(()=>items.filter(i=>i.item_type==="LOANABLE"),[items]);
 const cartLines=Object.entries(cart).filter(([,q])=>q>0).map(([id,q])=>({item:items.find(x=>x.id===id),quantity:q})).filter(x=>x.item);
 const borrowLines=Object.entries(borrowCart).filter(([,q])=>q>0).map(([id,q])=>({item:items.find(x=>x.id===id),quantity:q})).filter(x=>x.item);
 const subtotal=cartLines.reduce((n,x)=>n+Number(x.item.sale_price||0)*x.quantity,0);
 const tax=cartLines.reduce((n,x)=>n+Number(x.item.sale_price||0)*x.quantity*Number(x.item.tax_rate||0)/100,0);
 const setQty=(setter,id,delta,max=99)=>setter(v=>({...v,[id]:Math.max(0,Math.min(max,Number(v[id]||0)+delta))}));
 const submitOrder=async()=>{
  setBusy(true);setError("");setMessage("");
  try{
   const {data,error}=await supabase.functions.invoke("agent-inventory-store",{body:{action:"create_order",payment_method:payment,branch_id:branchId,items:cartLines.map(x=>({item_id:x.item.id,quantity:x.quantity})),notes}});
   if(error)throw error;if(data?.error)throw new Error(data.error);
   setCart({});setNotes("");await load();
   if(payment==="SQUARE"&&data.checkout_url){window.location.assign(data.checkout_url);return;}
   setMessage("Order "+data.order.order_number+" created. Send the exact amount by Interac e-Transfer to admin@dvrealty.ca and include the order number in the message. Your order remains pending until the office verifies payment.");
  }catch(e){
   let detail=e?.message||"Could not place order.";
   if(e?.context&&typeof e.context.clone==="function"){
    try{const payload=await e.context.clone().json();if(payload?.error)detail=payload.error;}catch{}
   }
   setError(detail);
  }finally{setBusy(false)}
 };
 const submitBorrow=async()=>{
  setBusy(true);setError("");setMessage("");
  try{
   const {data,error}=await supabase.functions.invoke("agent-inventory-store",{body:{action:"request_borrow",branch_id:branchId,pickup_date:pickup,due_date:due||null,notes,items:borrowLines.map(x=>({item_id:x.item.id,quantity:x.quantity}))}});
   if(error)throw error;if(data?.error)throw new Error(data.error);
   setBorrowCart({});setNotes("");setMessage("Borrow request "+data.request.request_number+" submitted. It will remain pending until an administrator reviews it.");await load();
  }catch(e){setError(e.message||"Could not submit request.")}finally{setBusy(false)}
 };
 const tabButton=(id,label,Icon)=><button onClick={()=>{setTab(id);setError("");setMessage("")}} style={{border:0,borderBottom:tab===id?"3px solid "+gold:"3px solid transparent",background:"transparent",padding:"12px 14px",fontWeight:700,color:tab===id?navy:"#667085",display:"inline-flex",alignItems:"center",gap:7,cursor:"pointer"}}><Icon size={17}/>{label}</button>;
 const card={border:"1px solid #e5e7eb",borderRadius:12,padding:14,background:"#fff"};
 const qtyControl=(value,onMinus,onPlus)=><div style={{display:"flex",alignItems:"center",gap:10}}><button className="secondary" type="button" onClick={onMinus} style={{padding:"5px 9px"}}><Minus size={14}/></button><strong>{value}</strong><button className="secondary" type="button" onClick={onPlus} style={{padding:"5px 9px"}}><Plus size={14}/></button></div>;
 return <div style={{display:"grid",gap:16}}>
  <div style={{background:navy,color:"#fff",borderRadius:14,padding:"20px 22px",display:"flex",justifyContent:"space-between",alignItems:"center",gap:14,flexWrap:"wrap"}}><div><div style={{fontSize:12,letterSpacing:1.2,color:"#d8c9a8",fontWeight:800}}>DREAM VALLEY REALTY</div><h2 style={{margin:"5px 0",fontSize:24}}>Agent Inventory Store</h2><div style={{color:"#e4e7ec"}}>Shop office products or request items to borrow</div></div><div style={{fontSize:13,color:"#e4e7ec"}}>{user?.email||"Agent"} · Agent Store</div></div>
  <div style={{display:"flex",alignItems:"center",gap:12,flexWrap:"wrap"}}><label style={{fontWeight:700}}>Branch for pickup</label><select value={branchId} onChange={e=>setBranchId(e.target.value)} style={{minWidth:220,padding:10,border:"1px solid #d0d5dd",borderRadius:8}}>{branches.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select><button className="secondary" onClick={()=>load().catch(e=>setError(e.message))}><RefreshCw size={15}/> Refresh</button></div>
  <div style={{display:"flex",borderBottom:"1px solid #e5e7eb",overflowX:"auto"}}>{tabButton("SHOP","Shop",Package)}{tabButton("BORROW","Borrow items",HandCoins)}{tabButton("ORDERS","My orders",ShoppingCart)}{tabButton("REQUESTS","Borrow requests",ClipboardList)}</div>
  {error&&<div className="notice" style={{color:"#b42318"}}>{error}</div>}{message&&<div className="notice" style={{color:"#067647"}}>{message}</div>}
  {tab==="SHOP"&&<div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(240px,1fr))",gap:14}}>
   {shopItems.map(item=><div key={item.id} style={card}><div style={{height:150,background:"#f2f4f7",borderRadius:9,display:"grid",placeItems:"center",overflow:"hidden",marginBottom:12}}>{item.image_url?<img src={item.image_url} alt={item.item_name} style={{width:"100%",height:"100%",objectFit:"contain"}}/>:<Package size={38} color="#98a2b3"/>}</div><div style={{fontWeight:800,color:navy}}>{item.item_name}</div><div style={{fontSize:12,color:"#667085",margin:"4px 0"}}>{item.item_code} · {item.category}</div>{item.description&&<p style={{fontSize:13,color:"#475467",minHeight:34}}>{item.description}</p>}<div style={{fontSize:18,fontWeight:800,margin:"10px 0"}}>{money(item.sale_price)} <small style={{fontSize:11,color:"#667085",fontWeight:500}}>+ HST {Number(item.tax_rate||0)}%</small></div><div style={{fontSize:12,color:"#667085",marginBottom:10}}>{item.item_type==="SERVICE"?"Service":available(item)+" available at selected branch"}</div><div style={{display:"flex",justifyContent:"space-between",alignItems:"center"}}>{qtyControl(cart[item.id]||0,()=>setQty(setCart,item.id,-1),()=>setQty(setCart,item.id,1,item.item_type==="SERVICE"?99:available(item)))}<button className="primary" type="button" onClick={()=>setQty(setCart,item.id,1,item.item_type==="SERVICE"?99:available(item))} disabled={item.item_type!=="SERVICE"&&available(item)<=0}>Add</button></div></div>)}
   {!shopItems.length&&<div className="panel">No products are currently listed for sale. Please check back later.</div>}
  </div>}
  {tab==="SHOP"&&<div className="panel" style={{marginTop:4}}><h3 style={{marginTop:0}}>Shopping cart ({cartLines.reduce((n,x)=>n+x.quantity,0)} items)</h3>{cartLines.map(x=><div key={x.item.id} style={{display:"flex",justifyContent:"space-between",gap:12,padding:"8px 0",borderBottom:"1px solid #eee"}}><span>{x.item.item_name} × {x.quantity}</span><strong>{money(x.quantity*Number(x.item.sale_price||0))}</strong></div>)}{!cartLines.length&&<div className="muted">Your cart is empty.</div>}<div style={{maxWidth:420,marginLeft:"auto",paddingTop:12}}><div style={{display:"flex",justifyContent:"space-between"}}>Subtotal <strong>{money(subtotal)}</strong></div><div style={{display:"flex",justifyContent:"space-between"}}>HST <strong>{money(tax)}</strong></div><div style={{display:"flex",justifyContent:"space-between",fontSize:18,fontWeight:800,borderTop:"1px solid #ddd",paddingTop:8,marginTop:8}}>Total <span>{money(subtotal+tax)}</span></div><label style={{display:"grid",gap:5,marginTop:12}}>Payment method<select value={payment} onChange={e=>setPayment(e.target.value)}><option value="SQUARE">Credit / Debit card (Square)</option><option value="INTERAC">Interac e-Transfer</option></select></label><label style={{display:"grid",gap:5,marginTop:10}}>Order notes<textarea rows={2} value={notes} onChange={e=>setNotes(e.target.value)} /></label><button className="primary" style={{width:"100%",marginTop:12,background:gold}} disabled={busy||!cartLines.length} onClick={submitOrder}>{busy?"Processing…":payment==="SQUARE"?"Continue to secure Square checkout":"Place e-Transfer order"}</button><div style={{fontSize:11,color:"#667085",marginTop:8}}>Stock is not deducted until payment is verified.</div></div></div>}
  {tab==="BORROW"&&<div className="panel"><h3 style={{marginTop:0}}>Request office items</h3><p className="muted">Select items and quantities. An administrator must approve the request before items are reserved or issued.</p><div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(220px,1fr))",gap:10}}>{borrowItems.map(item=><div key={item.id} style={{...card,display:"flex",gap:10,alignItems:"center"}}>{item.image_url?<img src={item.image_url} alt="" style={{width:58,height:58,objectFit:"cover",borderRadius:8}}/>:<Package size={28}/>}<div style={{flex:1}}><strong>{item.item_name}</strong><div className="muted" style={{fontSize:12}}>{available(item)} available</div>{qtyControl(borrowCart[item.id]||0,()=>setQty(setBorrowCart,item.id,-1),()=>setQty(setBorrowCart,item.id,1,available(item)))}</div></div>)}</div><div className="grid two" style={{marginTop:16}}><label>Pickup date<input type="date" value={pickup} onChange={e=>setPickup(e.target.value)}/></label><label>Expected return date<input type="date" min={pickup} value={due} onChange={e=>setDue(e.target.value)}/></label></div><label style={{display:"grid",gap:5,marginTop:10}}>Notes<textarea rows={2} value={notes} onChange={e=>setNotes(e.target.value)}/></label><button className="primary" disabled={busy||!borrowLines.length} onClick={submitBorrow} style={{marginTop:12,background:gold}}>{busy?"Submitting…":"Submit borrowing request ("+borrowLines.length+")"}</button></div>}
  {tab==="ORDERS"&&<div className="panel"><h3 style={{marginTop:0}}>My orders</h3>{orders.length?<div style={{overflowX:"auto"}}><table><thead><tr><th>Order</th><th>Date</th><th>Items</th><th>Total</th><th>Payment</th><th>Order status</th></tr></thead><tbody>{orders.map(o=><tr key={o.id}><td>{o.order_number}</td><td>{new Date(o.created_at).toLocaleDateString("en-CA")}</td><td>{(o.items||[]).map(x=>x.item_name+" × "+x.quantity).join(", ")}</td><td>{money(o.total_amount)}</td><td>{o.payment_method} · {o.payment_status}</td><td>{o.order_status}</td></tr>)}</tbody></table></div>:<p className="muted">No orders yet.</p>}</div>}
  {tab==="REQUESTS"&&<div className="panel"><h3 style={{marginTop:0}}>My borrowing requests</h3>{requests.length?<div style={{overflowX:"auto"}}><table><thead><tr><th>Request</th><th>Date</th><th>Items</th><th>Pickup</th><th>Due</th><th>Status</th><th>Admin notes</th></tr></thead><tbody>{requests.map(r=><tr key={r.id}><td>{r.request_number}</td><td>{new Date(r.created_at).toLocaleDateString("en-CA")}</td><td>{(r.items||[]).map(x=>x.item_name+" × "+x.quantity).join(", ")}</td><td>{r.pickup_date||"—"}</td><td>{r.due_date||"—"}</td><td>{r.status}</td><td>{r.admin_notes||"—"}</td></tr>)}</tbody></table></div>:<p className="muted">No borrowing requests yet.</p>}</div>}
 </div>;
}