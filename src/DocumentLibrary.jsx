import { useCallback, useEffect, useState } from "react";
import { Archive, BookOpen, CheckCircle2, ExternalLink, FilePlus2, FileText, Plus, Save, Trash2, Upload } from "lucide-react";
import { supabase } from "./lib/supabase";

const BUCKET = "dv-paperwork-reference";
const CATEGORIES = [
  ["AGREEMENT", "Agreements"],
  ["SCHEDULE", "Schedules"],
  ["DISCLOSURE", "Disclosures"],
  ["REPRESENTATION", "Representation"],
  ["BROKERAGE", "Brokerage Forms"],
  ["COMPLIANCE", "Compliance"],
  ["OTHER", "Other"]
];
const ADMIN_ROLES = ["SUPERADMIN", "ADMIN", "BROKER_OF_RECORD", "BROKER OF RECORD", "BROKER", "MANAGER", "MANAGEMENT"];
const newRule = () => ({ id: typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random(), label: "", page: 1, stage: "PRE_SIGN", kind: "FIELD", field_key: "", required: true, condition: "" });
const safeName = name => String(name || "reference.pdf").normalize("NFKD").replace(/[^a-zA-Z0-9._-]+/g, "_").slice(-120);
async function detectReferenceRules(file) {
  try {
    const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
    const workerUrl = (await import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url")).default;
    pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    const rules = [];
    try {
      for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
        const page = await pdf.getPage(pageNumber);
        const annotations = await page.getAnnotations({ intent: "display" });
        annotations.filter(item => item.subtype === "Widget" && item.fieldName).forEach(item => {
          const fieldType = String(item.fieldType || "Text");
          const kind = fieldType === "Sig" ? "SIGNATURE" : fieldType === "Btn" ? "CHECKBOX" : "FIELD";
          const required = Boolean((Number(item.fieldFlags) || 0) & 2) || fieldType === "Sig";
          rules.push({
            id: (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random()),
            label: String(item.fieldName),
            field_key: String(item.fieldName),
            page: pageNumber,
            stage: fieldType === "Sig" ? "POST_SIGN" : "PRE_SIGN",
            kind,
            required,
            condition: ""
          });
        });
      }
    } finally { pdf.destroy(); }
    return rules;
  } catch {
    return [];
  }
}


export default function DocumentLibrary({ user, adminMode = false, role = "" }) {
  const canManage = adminMode || ADMIN_ROLES.includes(String(role).toUpperCase());
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [editing, setEditing] = useState(null);
  const [rules, setRules] = useState([]);
  const [draft, setDraft] = useState({ document_name: "", category: "AGREEMENT", version: "1.0", effective_date: "", notes: "", file: null });

  const load = useCallback(async () => {
    if (!supabase) { setError("Database connection is unavailable."); setLoading(false); return; }
    setLoading(true);
    const { data, error: queryError } = await supabase.from("dv_accounting_paperwork_library")
      .select("id,document_name,category,version,effective_date,status,storage_path,original_file_name,mime_type,file_size,validation_rules,notes,created_at,published_at")
      .order("document_name", { ascending: true }).order("created_at", { ascending: false });
    if (queryError) { setError(queryError.message); setRows([]); }
    else { setRows(data || []); setError(""); }
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  function editRules(row) {
    setEditing(row);
    setRules(Array.isArray(row.validation_rules) ? row.validation_rules : []);
    setError("");
    setMessage("");
  }

  async function addReference() {
    if (!canManage) return;
    if (!draft.document_name.trim() || !draft.version.trim() || !draft.file) {
      setError("Enter the form name and version, and choose its official blank PDF.");
      return;
    }
    if (draft.file.type !== "application/pdf" && !/\.pdf$/i.test(draft.file.name)) {
      setError("Reference forms must be uploaded as PDF files.");
      return;
    }
    if (draft.file.size > 20 * 1024 * 1024) {
      setError("The reference PDF must be 20 MB or smaller.");
      return;
    }
    setSaving(true); setError(""); setMessage("");
    const id = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + "-" + Math.random();
    const storagePath = "forms/" + id + "/" + safeName(draft.file.name);
    try {
      const { error: uploadError } = await supabase.storage.from(BUCKET).upload(storagePath, draft.file, {
        contentType: "application/pdf", upsert: false
      });
      if (uploadError) throw uploadError;
      const { data: authData } = await supabase.auth.getUser();
      const { error: insertError } = await supabase.from("dv_accounting_paperwork_library").insert({
        id, document_name: draft.document_name.trim(), category: draft.category, version: draft.version.trim(),
        effective_date: draft.effective_date || null, status: "DRAFT", storage_path: storagePath,
        original_file_name: draft.file.name, mime_type: "application/pdf", file_size: draft.file.size,
        validation_rules: detectedRules, notes: draft.notes.trim() || null, created_by: authData?.user?.id || user?.id || null,
        updated_by: authData?.user?.id || user?.id || null
      });
      if (insertError) {
        await supabase.storage.from(BUCKET).remove([storagePath]);
        throw insertError;
      }
      setDraft({ document_name: "", category: "AGREEMENT", version: "1.0", effective_date: "", notes: "", file: null });
      const picker = document.getElementById("paperwork-reference-file");
      if (picker) picker.value = "";
      setMessage("Reference form added as a draft. " + detectedRules.length + " fillable field(s) detected; review the rules and mark all required items before publishing.");
      await load();
    } catch (e) { setError(e?.message || "Could not add the reference form."); }
    finally { setSaving(false); }
  }

  async function saveRules() {
    if (!editing || !canManage) return;
    const invalid = rules.find(rule => !String(rule.label || "").trim() || !Number.isInteger(Number(rule.page)) || Number(rule.page) < 1);
    if (invalid) { setError("Every rule needs a field or section name and a valid page number."); return; }
    setSaving(true); setError(""); setMessage("");
    try {
      const { data: authData } = await supabase.auth.getUser();
      const { error: updateError } = await supabase.from("dv_accounting_paperwork_library").update({
        validation_rules: rules.map(rule => ({ ...rule, label: String(rule.label).trim(), page: Number(rule.page) })),
        updated_by: authData?.user?.id || user?.id || null,
        updated_at: new Date().toISOString()
      }).eq("id", editing.id);
      if (updateError) throw updateError;
      setMessage("Completion rules saved.");
      setEditing(null);
      await load();
    } catch (e) { setError(e?.message || "Could not save the completion rules."); }
    finally { setSaving(false); }
  }

  async function changeStatus(row, status) {
    if (!canManage) return;
    setSaving(true); setError(""); setMessage("");
    const { data: authData } = await supabase.auth.getUser();
    if (status === "PUBLISHED") {
      const { error: archiveError } = await supabase.from("dv_accounting_paperwork_library")
        .update({ status: "ARCHIVED", updated_at: new Date().toISOString(), updated_by: authData?.user?.id || user?.id || null })
        .eq("document_name", row.document_name).eq("status", "PUBLISHED").neq("id", row.id);
      if (archiveError) { setError(archiveError.message); setSaving(false); return; }
    }
    const { error: updateError } = await supabase.from("dv_accounting_paperwork_library").update({
      status, published_at: status === "PUBLISHED" ? new Date().toISOString() : null,
      updated_by: authData?.user?.id || user?.id || null, updated_at: new Date().toISOString()
    }).eq("id", row.id);
    if (updateError) setError(updateError.message);
    else setMessage(status === "PUBLISHED" ? "Reference form published for agent validation." : "Reference form archived.");
    await load();
    setSaving(false);
  }

  async function openReference(row) {
    const { data, error: signedError } = await supabase.storage.from(BUCKET).createSignedUrl(row.storage_path, 300);
    if (signedError) { setError(signedError.message); return; }
    if (data?.signedUrl) window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  if (!canManage) return <section className="panel"><h2>Document Library</h2><p className="muted">You do not have permission to manage reference forms.</p></section>;

  return <div className="panel" style={{ maxWidth: 1180, margin: "0 auto" }}>
    <div className="paneltitle"><div><h2><BookOpen size={22} style={{ verticalAlign: "middle", marginRight: 8 }}/>Document Library</h2>
      <p className="muted">Manage official blank forms, versions and the completion rules used by Paperwork Validation.</p></div>
      <button className="secondary" type="button" onClick={load}>Refresh</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 18 }}>
      <strong>Reference documents only</strong>
      <div className="muted">Only official blank reference forms belong here. Completed agent paperwork is checked temporarily in Paperwork Validation and is never added to this library.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}
    <section style={{ border: "1px solid #e4e7ec", borderRadius: 10, padding: 14, marginBottom: 20 }}>
      <h3 style={{ marginTop: 0 }}><FilePlus2 size={17} style={{ verticalAlign: "middle", marginRight: 6 }}/>Add a reference form or new version</h3>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(190px,1fr))", gap: 10 }}>
        <label>Form name<input style={{ width: "100%", marginTop: 5 }} value={draft.document_name} onChange={e => setDraft(v => ({ ...v, document_name: e.target.value }))} placeholder="e.g. Agreement of Purchase and Sale"/></label>
        <label>Category<select style={{ width: "100%", marginTop: 5 }} value={draft.category} onChange={e => setDraft(v => ({ ...v, category: e.target.value }))}>{CATEGORIES.map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label>Version<input style={{ width: "100%", marginTop: 5 }} value={draft.version} onChange={e => setDraft(v => ({ ...v, version: e.target.value }))} placeholder="e.g. 2026-01"/></label>
        <label>Effective date<input type="date" style={{ width: "100%", marginTop: 5 }} value={draft.effective_date} onChange={e => setDraft(v => ({ ...v, effective_date: e.target.value }))}/></label>
      </div>
      <label style={{ display: "block", marginTop: 10 }}>Admin notes<textarea rows={2} style={{ width: "100%", marginTop: 5 }} value={draft.notes} onChange={e => setDraft(v => ({ ...v, notes: e.target.value }))} placeholder="Source, form changes, instructions…"/></label>
      <label style={{ display: "block", marginTop: 10 }}>Official blank PDF<input id="paperwork-reference-file" type="file" accept=".pdf,application/pdf" style={{ display: "block", marginTop: 5 }} onChange={e => setDraft(v => ({ ...v, file: e.target.files?.[0] || null }))}/></label>
      <button className="primary" type="button" disabled={saving} onClick={addReference} style={{ marginTop: 12 }}><Upload size={16}/> {saving ? "Saving…" : "Upload reference form"}</button>
    </section>

    {editing && <section style={{ border: "1px solid #d6b979", borderRadius: 10, padding: 14, marginBottom: 20 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10, flexWrap: "wrap" }}>
        <div><h3 style={{ margin: 0 }}>Completion rules: {editing.document_name} v{editing.version}</h3><p className="muted" style={{ margin: "5px 0 0" }}>Define fields and sections the validator should expect on this form.</p></div>
        <button className="secondary" type="button" onClick={() => setEditing(null)}>Close</button>
      </div>
      <div style={{ display: "grid", gap: 8, marginTop: 14 }}>
        {rules.map((rule,index) => <div key={rule.id || index} style={{ display: "grid", gridTemplateColumns: "minmax(160px,1.2fr) minmax(130px,1fr) 65px 125px 115px 75px 36px", gap: 7, alignItems: "center" }}>
          <input aria-label="Field or section label" value={rule.label} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, label: e.target.value } : item))} placeholder="Checklist label"/>
          <input aria-label="PDF field name" value={rule.field_key || ""} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, field_key: e.target.value } : item))} placeholder="PDF field name (optional)"/>
          <input aria-label="Page number" type="number" min="1" value={rule.page} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, page: e.target.value } : item))}/>
          <select aria-label="Check stage" value={rule.stage || "PRE_SIGN"} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, stage: e.target.value } : item))}><option value="PRE_SIGN">Before signing</option><option value="POST_SIGN">After signing</option><option value="BOTH">Both stages</option></select>
          <select aria-label="Field type" value={rule.kind || "FIELD"} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, kind: e.target.value } : item))}><option value="FIELD">Field</option><option value="CHECKBOX">Checkbox</option><option value="DATE">Date</option><option value="INITIAL">Initials</option><option value="SIGNATURE">Signature</option></select>
          <label style={{ display: "flex", gap: 5, alignItems: "center", fontSize: 12 }}><input type="checkbox" checked={rule.required !== false} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, required: e.target.checked } : item))}/>Required</label>
          <button className="textbutton" type="button" aria-label="Remove rule" onClick={() => setRules(list => list.filter((_,i) => i!==index))}><Trash2 size={16}/></button>
          <input style={{ gridColumn: "1 / -1" }} value={rule.condition || ""} onChange={e => setRules(list => list.map((item,i) => i===index ? { ...item, condition: e.target.value } : item))} placeholder="Condition (optional), e.g. required only when a property has a rental water heater"/>
        </div>)}
      </div>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 12 }}>
        <button className="secondary" type="button" onClick={() => setRules(list => [...list, newRule()])}><Plus size={15}/> Add required item</button>
        <button className="primary" type="button" disabled={saving} onClick={saveRules}><Save size={15}/> Save rules</button>
      </div>
    </section>}

    <h3>Reference forms and versions</h3>
    {loading ? <p className="muted">Loading library…</p> : !rows.length ? <p className="muted">No reference forms have been added yet.</p> : <div style={{ overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 760 }}>
        <thead><tr>{["Form","Category","Version","Effective","Status","Rules","Actions"].map(label => <th key={label} style={{ textAlign: "left", padding: 9, borderBottom: "1px solid #e4e7ec" }}>{label}</th>)}</tr></thead>
        <tbody>{rows.map(row => <tr key={row.id}>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}><strong>{row.document_name}</strong><div className="muted" style={{ fontSize: 12 }}>{row.original_file_name}</div></td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}>{CATEGORIES.find(x => x[0]===row.category)?.[1] || row.category}</td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}>{row.version}</td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}>{row.effective_date || "—"}</td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}><span className="badge">{row.status}</span></td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}>{Array.isArray(row.validation_rules) ? row.validation_rules.length : 0}</td>
          <td style={{ padding: 9, borderBottom: "1px solid #e4e7ec" }}><div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <button className="secondary" type="button" onClick={() => openReference(row)} title="Open blank reference"><ExternalLink size={14}/></button>
            <button className="secondary" type="button" onClick={() => editRules(row)} title="Edit completion rules">Rules</button>
            {row.status !== "PUBLISHED" && <button className="secondary" type="button" disabled={saving} onClick={() => changeStatus(row,"PUBLISHED")}><CheckCircle2 size={14}/> Publish</button>}
            {row.status !== "ARCHIVED" && <button className="textbutton" type="button" disabled={saving} onClick={() => changeStatus(row,"ARCHIVED")} title="Archive version"><Archive size={15}/></button>}
          </div></td>
        </tr>)}</tbody>
      </table>
    </div>}
    <p className="muted" style={{ marginTop: 14, fontSize: 12 }}>Publishing makes a reference form available to agents. Archive old versions instead of deleting them so earlier validation rules remain traceable.</p>
  </div>;
}
