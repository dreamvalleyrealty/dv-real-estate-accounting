import React, { useMemo, useState } from "react";

const roles = ["SUPERADMIN", "ADMIN", "MANAGER", "ACCOUNTANT", "STAFF", "VIEWER"];
const catalog = [
  ["dashboard.view","Dashboard","View dashboard"],
  ["transactions.view","Transactions","View transactions"],
  ["transactions.create","Transactions","Create transactions"],
  ["transactions.edit","Transactions","Edit transactions"],
  ["transactions.finalize","Transactions","Finalize transactions"],
  ["banking.view","Banking","View banking"],
  ["banking.reconcile","Banking","Reconcile accounts"],
  ["expenses.view","Expenses & A/P","View expenses"],
  ["expenses.create","Expenses & A/P","Create expenses"],
  ["expenses.edit","Expenses & A/P","Edit expenses"],
  ["expenses.pay","Expenses & A/P","Pay expenses"],
  ["agents.view","Agents","View agents"],
  ["agents.create","Agents","Create agents"],
  ["agents.edit","Agents","Edit agents"],
  ["agents.import","Agents","Import agent lists"],
  ["agents.delete","Agents","Delete agents"],
  ["agents.documents.view","Agents","View agent documents"],
  ["agents.documents.manage","Agents","Manage agent documents"],
  ["fees.view","Agent Fees","View fee plans"],
  ["fees.manage","Agent Fees","Manage fee plans"],
  ["commission.view","Commission Payroll","View commission payroll"],
  ["commission.preview","Commission Payroll","Preview commission deductions"],
  ["commission.issue","Commission Payroll","Issue commission cheques"],
  ["staff.view","Staff Payroll","View staff"],
  ["staff.create","Staff Payroll","Create staff"],
  ["staff.edit","Staff Payroll","Edit staff"],
  ["staff.hours.manage","Staff Payroll","Manage staff hours"],
  ["staff.documents.view","Staff Payroll","View staff documents"],
  ["staff.documents.manage","Staff Payroll","Manage staff documents"],
  ["payroll.view","Staff Payroll","View payroll"],
  ["payroll.calculate","Staff Payroll","Calculate payroll"],
  ["payroll.approve","Staff Payroll","Approve payroll"],
  ["payroll.post","Staff Payroll","Post payroll"],
  ["payroll.remit","Staff Payroll","Manage CRA remittances"],
  ["tax.view","HST / Tax","View tax"],
  ["tax.manage","HST / Tax","Manage tax"],
  ["reports.view","Reports","View reports"],
  ["reports.export","Reports","Export reports"],
  ["compliance.view","Compliance","View compliance"],
  ["compliance.close","Compliance","Close month end"],
  ["settings.view","Settings","View settings"],
  ["settings.company.manage","Settings","Manage company settings"],
  ["settings.banking.manage","Settings","Manage bank accounts"],
  ["settings.users.manage","Settings","Manage users"],
  ["settings.roles.manage","Settings","Manage roles and permissions"]
];

const managerAllow = new Set("dashboard.view transactions.view transactions.create transactions.edit banking.view expenses.view expenses.create expenses.edit agents.view agents.create agents.edit agents.import agents.documents.view agents.documents.manage fees.view fees.manage commission.view commission.preview commission.issue staff.view staff.create staff.edit staff.hours.manage staff.documents.view reports.view reports.export compliance.view settings.view".split(" "));
const accountantModules = new Set(["Dashboard","Transactions","Banking","Expenses & A/P","Commission Payroll","Staff Payroll","HST / Tax","Reports","Compliance"]);
const accountantDeny = new Set("transactions.create transactions.edit transactions.finalize banking.reconcile expenses.create expenses.edit expenses.pay commission.issue staff.create staff.edit staff.hours.manage payroll.approve payroll.post tax.manage compliance.close".split(" "));
const staffAllow = new Set(["dashboard.view","agents.view","staff.view","staff.hours.manage","reports.view"]);

function roleAllows(role, code, module) {
  if (role === "SUPERADMIN" || role === "ADMIN") return true;
  if (role === "MANAGER") return managerAllow.has(code);
  if (role === "ACCOUNTANT") return accountantModules.has(module) && !accountantDeny.has(code);
  if (role === "STAFF") return staffAllow.has(code);
  return code === "dashboard.view" || code === "reports.view";
}

const th = { textAlign:"left", padding:"10px 12px", borderBottom:"1px solid #e4e7ec", background:"#f8fafc", position:"sticky", top:0, zIndex:1, whiteSpace:"nowrap" };
const td = { padding:"9px 12px", borderBottom:"1px solid #eaecf0", fontSize:13, verticalAlign:"middle" };
const pill = ok => ({display:"inline-block",minWidth:48,textAlign:"center",padding:"3px 8px",borderRadius:20,fontSize:11,fontWeight:700,color:ok?"#067647":"#b42318",background:ok?"#ecfdf3":"#fef3f2"});

export default function FinancialPermissionMatrix() {
  const [query,setQuery] = useState("");
  const [role,setRole] = useState("ALL");
  const rows = useMemo(() => catalog.filter(([code,module,label]) => {
    const q=query.trim().toLowerCase();
    return (!q || code.toLowerCase().includes(q) || module.toLowerCase().includes(q) || label.toLowerCase().includes(q)) && (role==="ALL" || roleAllows(role,code,module));
  }),[query,role]);

  return <div>
    <div className="pagehead"><div><h1>Financial Permission Test Matrix</h1><p>Temporary, read-only reference based on the role-template logic in migration 0030. This page does not change permissions or financial records.</p></div></div>
    <section className="panel" style={{borderLeft:"4px solid #9e8556",marginBottom:16}}>
      <strong>Important: template baseline, not live user access</strong>
      <p className="muted" style={{margin:"7px 0 0"}}>Actual access can differ because the database may contain existing role rules and user-specific overrides. Explicit user denies should take precedence over role grants. Scope must also be enforced by the database.</p>
    </section>
    <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(150px,1fr))",gap:10,marginBottom:16}}>
      {roles.map(r=><div className="panel" key={r} style={{padding:12}}><div className="muted" style={{fontSize:11}}>{r}</div><strong style={{fontSize:13}}>{r==="SUPERADMIN"||r==="ADMIN"?"All catalog permissions":r==="MANAGER"?"Manager allow-list":r==="ACCOUNTANT"?"Finance modules with exclusions":r==="STAFF"?"Limited staff access":"Dashboard and reports"}</strong><div className="muted" style={{fontSize:12,marginTop:4}}>Default scope: {r==="STAFF"?"OWN":"ALL"}</div></div>)}
    </div>
    <section className="panel" style={{marginBottom:16}}>
      <div style={{display:"flex",gap:12,alignItems:"center",flexWrap:"wrap",justifyContent:"space-between",marginBottom:12}}>
        <div><h2 style={{margin:"0 0 4px"}}>Permission catalog ({catalog.length})</h2><p className="muted" style={{margin:0}}>Allow/deny values below are calculated from the migration's seeded role templates.</p></div>
        <div style={{display:"flex",gap:8,flexWrap:"wrap"}}>
          <input aria-label="Search permissions" placeholder="Search permissions…" value={query} onChange={e=>setQuery(e.target.value)} style={{minWidth:220,padding:"9px 10px",border:"1px solid #d0d5dd",borderRadius:8}}/>
          <select aria-label="Filter role" value={role} onChange={e=>setRole(e.target.value)} style={{padding:"9px 10px",border:"1px solid #d0d5dd",borderRadius:8}}><option value="ALL">All roles</option>{roles.map(r=><option key={r} value={r}>{r}</option>)}</select>
        </div>
      </div>
      <div style={{overflowX:"auto",maxHeight:620,overflowY:"auto"}}>
        <table style={{width:"100%",borderCollapse:"collapse",minWidth:role==="ALL"?900:580}}>
          <thead><tr><th style={th}>Permission</th><th style={th}>Module</th>{(role==="ALL"?roles:[role]).map(r=><th key={r} style={{...th,textAlign:"center"}}>{r}</th>)}</tr></thead>
          <tbody>{rows.map(([code,module,label])=><tr key={code}><td style={td}><strong>{label}</strong><div className="muted" style={{fontSize:11}}>{code}</div></td><td style={td}>{module}</td>{(role==="ALL"?roles:[role]).map(r=><td key={r} style={{...td,textAlign:"center"}}><span style={pill(roleAllows(r,code,module))}>{roleAllows(r,code,module)?"ALLOW":"DENY"}</span></td>)}</tr>)}</tbody>
        </table>
        {!rows.length&&<p className="muted" style={{padding:16}}>No matching permissions.</p>}
      </div>
    </section>
    <section className="panel" style={{marginBottom:16}}>
      <h2 style={{marginTop:0}}>Override and scope test cases</h2>
      <div style={{overflowX:"auto"}}><table style={{width:"100%",borderCollapse:"collapse",minWidth:650}}><thead><tr><th style={th}>Role default</th><th style={th}>User override</th><th style={th}>Expected effective result</th></tr></thead><tbody>
        {[["Allow","Explicit deny","DENY"],["Deny","Explicit allow","ALLOW, subject to scope"],["Allow","No override","ALLOW"],["Deny","No override","DENY"],["Missing rule","No override","DENY"],["Any","Override for another user","No effect"]].map(row=><tr key={row.join("-")}>{row.map((v,i)=><td style={td} key={i}>{v}</td>)}</tr>)}
      </tbody></table></div>
      <h3>Scope expectations</h3>
      <div style={{overflowX:"auto"}}><table style={{width:"100%",borderCollapse:"collapse",minWidth:600}}><thead><tr><th style={th}>Scope</th><th style={th}>Own record</th><th style={th}>Same-branch other owner</th><th style={th}>Different branch</th></tr></thead><tbody>
        {[[ "ALL","Allow","Allow","Allow"],["BRANCH","Allow","Allow","Deny"],["OWN","Allow","Deny","Deny"]].map(row=><tr key={row[0]}>{row.map((v,i)=><td style={td} key={i}>{v}</td>)}</tr>)}
      </tbody></table></div>
    </section>
    <section className="panel">
      <h2 style={{marginTop:0}}>High-risk financial checks</h2>
      <ul style={{marginBottom:0,lineHeight:1.8}}>
        <li>Transaction finalization: authorization, target scope, balanced journal, idempotency and reversal.</li>
        <li>Bank reconciliation: correct bank account and period, independent reviewer and authenticated sign-off.</li>
        <li>Expense payment: approved and posted expense, correct funding account, atomic bank/GL posting.</li>
        <li>Commission cheque: approved commission, correct deductions/HST evidence and duplicate prevention.</li>
        <li>Payroll approval and posting: separation of duties, approval evidence and duplicate-post prevention.</li>
        <li>HST and month-end: open-period validation, source evidence and immutable close history.</li>
      </ul>
    </section>
  </div>;
}
