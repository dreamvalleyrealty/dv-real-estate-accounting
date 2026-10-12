import {useMemo,useState} from "react";

export default function AgentSearchSelect({agents=[],value="",onChange,placeholder="Search agent name...",style={},disabled=false,excludeIds=[]}) {
 const [query,setQuery]=useState("");
 const options=useMemo(()=>agents.filter(a=>!excludeIds.includes(a.id)).map(a=>({id:String(a.id),label:[a.first_name,a.last_name].filter(Boolean).join(" ")||a.full_name||a.name||a.agent_name||a.email||a.id,number:a.agent_number||"",email:a.email||""})),[agents,excludeIds]);
 const selected=options.find(a=>a.id===String(value));
 const filtered=options.filter(a=>(a.label+" "+a.number+" "+a.email).toLowerCase().includes(query.toLowerCase()));
 const field={width:"100%",boxSizing:"border-box",minHeight:36,padding:"7px 9px",border:"1px solid #d0d5dd",borderRadius:6,...style};
 return <div style={{display:"grid",gap:5}}>
  <input aria-label="Search agents by name" disabled={disabled} style={field} value={query} placeholder={selected&&!query?selected.label:placeholder} onChange={e=>setQuery(e.target.value)} onFocus={()=>{if(selected&&!query)setQuery("")}} />
  <select aria-label="Select agent" disabled={disabled} style={field} value={value||""} onChange={e=>{onChange(e.target.value);setQuery("")}}>
   <option value="">{query?"Choose from "+filtered.length+" matching agent(s)":"Select agent"}</option>
   {filtered.map(a=><option key={a.id} value={a.id}>{a.label}{a.number?" · "+a.number:""}</option>)}
  </select>
  {query&&!filtered.length&&<small style={{color:"#667085"}}>No agents match “{query}”. Try another name.</small>}
 </div>;
}