import { useEffect, useMemo, useState } from "react";
import { AlertCircle, CheckCircle2, FileCheck2, FileText, RefreshCw, Trash2, Upload } from "lucide-react";
import { supabase } from "./lib/supabase";
import { validateOfferPackage, validateOfferPostSignature } from "./lib/offerValidation";

const DEFAULT_TYPES = [["APS","Agreement of Purchase and Sale / Lease"],["MLS","MLS / Listing sheet"],["COMMISSION","Commission confirmation"],["ID","Identity / compliance document"],["OTHER","Other supporting document"]];
const labelFor = (type, types) => types.find(item => item[0] === type)?.[1] || type;
const cleanPayload = row => ({ ...(row?.payload || {}), side: String(row?.representation_side || row?.payload?.side || "SELLER").toUpperCase() });
const isPdf = file => /pdf/i.test(file?.type || "") || /\.pdf$/i.test(file?.name || "");

export default function PaperworkValidation({ user, agentId, adminMode = false, isActive = true }) {
  const [trades, setTrades] = useState([]);
  const [tradeId, setTradeId] = useState("");
  const [types, setTypes] = useState(DEFAULT_TYPES);
  const [requirements, setRequirements] = useState({});
  const [files, setFiles] = useState([]);
  const [reports, setReports] = useState({ pre: null, post: null });
  const [confirmations, setConfirmations] = useState({});
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const selected = useMemo(() => trades.find(row => String(row.id) === String(tradeId)) || null, [trades, tradeId]);
  const form = useMemo(() => cleanPayload(selected), [selected]);
  const side = String(form.side || "SELLER").toUpperCase();
  const sideRules = requirements[side] || requirements[side === "LANDLORD" ? "SELLER" : side] || {};
  const requiredTypes = Array.isArray(sideRules.required) ? sideRules.required : (Array.isArray(sideRules.types) ? sideRules.types : ["APS","MLS","COMMISSION"]);
  const requiredCounts = sideRules.counts || {};
  const postClients = reports.post?.clients || [];

  useEffect(() => {
    let live = true;
    async function load() {
      setLoading(true); setError("");
      if (!supabase) { setError("Database connection is unavailable."); setLoading(false); return; }
      if (!adminMode && !agentId) { setError("Your agent profile could not be matched to your login."); setTrades([]); setLoading(false); return; }
      let query = supabase.from("dv_accounting_agent_trade_submissions")
        .select("id,agent_id,payload,transaction_id,trade_number,status,created_at,representation_side")
        .order("created_at", { ascending: false }).limit(adminMode ? 500 : 250);
      const { data, error: queryError } = await query;
      if (!live) return;
      if (queryError) { setError(queryError.message); setTrades([]); }
      else {
        const rows = (data || []).filter(row => adminMode ||
          String(row.agent_id) === String(agentId) ||
          (Array.isArray(row.payload?.additional_own_side_agents) && row.payload.additional_own_side_agents.some(a => String(a.agent_id || a.id) === String(agentId))));
        setTrades(rows);
      }
      try {
        const { data: company } = await supabase.from("dv_accounting_companies").select("id").limit(1).maybeSingle();
        if (company?.id) {
          const keys = ["TRADE_REQUIRED_DOCUMENT_TYPES","TRADE_DOCUMENT_TYPES","TRADE_REQUIRED_DOCUMENT_COUNTS","TRADE_DOCUMENT_REQUIREMENTS_BY_SIDE"];
          const results = await Promise.all(keys.map(key => supabase.from("dv_accounting_settings").select("value").eq("company_id", company.id).eq("key", key).maybeSingle()));
          if (!live) return;
          const [required, custom, counts, bySide] = results.map(result => result.data?.value);
          let docTypes = Array.isArray(custom) && custom.length ? custom.filter(x => Array.isArray(x) && x.length >= 2) : DEFAULT_TYPES;
          if (!docTypes.some(x => x[0] === "OTHER")) docTypes = [...docTypes, ["OTHER","Other supporting document"]];
          setTypes(docTypes);
          const globalTypes = Array.isArray(required) ? required : ["APS","MLS","COMMISSION"];
          if (bySide && typeof bySide === "object") {
            const normalized = { ...bySide };
            if (!normalized.SELLER && normalized.LISTING) normalized.SELLER = normalized.LISTING;
            setRequirements(normalized);
          } else {
            setRequirements(Object.fromEntries(["SELLER","BUYER","LANDLORD","TENANT"].map(key => [key,{ types: globalTypes, required: globalTypes, counts: counts || {} }])));
          }
        }
      } catch { /* Defaults remain usable if optional settings are unavailable. */ }
      setLoading(false);
    }
    load();
    return () => { live = false; };
  }, [adminMode, agentId]);

  function resetValidation() { setFiles([]); setReports({ pre: null, post: null }); setConfirmations({}); setError(""); setMessage(""); }
  function chooseTrade(id) { setTradeId(id); resetValidation(); }

  function addFiles(list) {
    const picked = Array.from(list || []);
    if (!picked.length) return;
    setFiles(current => [...current, ...picked.map((file, index) => ({
      id: (typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + "-" + index),
      file, type: "APS"
    }))]);
    setReports({ pre: null, post: null }); setMessage(""); setError("");
  }

  async function extractText(file) {
    if (!isPdf(file)) return "";
    const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
    const workerUrl = (await import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url")).default;
    pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    let text = "";
    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
      const page = await pdf.getPage(pageNumber);
      const content = await page.getTextContent();
      const rows = new Map();
      for (const item of content.items || []) {
        const value = String(item.str || "").trim(); if (!value) continue;
        const y = Math.round((item.transform?.[5] || 0) / 2) * 2;
        const row = rows.get(y) || []; row.push(value); rows.set(y, row);
      }
      text += [...rows.entries()].sort((a,b) => b[0]-a[0]).map(([,parts]) => parts.join(" ")).join("\n") + "\n";
    }
    if (text.trim().length < 80) {
      const { createWorker } = await import("tesseract.js");
      const worker = await createWorker("eng");
      try {
        let ocr = "";
        for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
          const page = await pdf.getPage(pageNumber), viewport = page.getViewport({ scale: 1.35 });
          const canvas = document.createElement("canvas");
          canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
          await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise;
          const result = await worker.recognize(canvas); ocr += "\n" + String(result?.data?.text || "");
          canvas.width = 0; canvas.height = 0;
        }
        if (ocr.trim().length > text.trim().length) text = ocr;
      } finally { await worker.terminate(); }
    }
    pdf.destroy();
    return text;
  }

  async function runPreCheck() {
    if (!selected) { setError("Select a trade first."); return; }
    if (!files.length) { setError("Add the offer and supporting documents first."); return; }
    setBusy(true); setError(""); setMessage(""); setReports({ pre: null, post: null });
    try {
      const extracted = [];
      for (const item of files) {
        let text = "";
        try { text = await extractText(item.file); } catch { /* Report unreadable PDFs below. */ }
        extracted.push({ id: item.id, name: item.file.name, document_type: item.type, text });
      }
      const docs = files.map(item => ({ id: item.id, document_name: item.file.name, document_type: item.type, mime_type: item.file.type, file_size: item.file.size, match_status: "APPROVED" }));
      const report = validateOfferPackage({
        form, docs,
        requirements: Object.keys(requirements).length ? requirements : { [side]: { types: requiredTypes, required: requiredTypes, counts: requiredCounts } },
        requirementExceptions: [], documentTexts: extracted
      });
      extracted.filter(item => isPdf(files.find(f => f.id === item.id)?.file) && !item.text.trim()).forEach(item => report.warnings.push({
        severity: "warning", code: "pdf_unreadable_" + item.id, title: "Could not read " + item.name,
        detail: "The file could not be read automatically. Open the original and review it manually."
      }));
      report.checkedDocuments = files.length;
      report.readableDocuments = extracted.filter(item => item.text.trim()).length;
      setReports(current => ({ ...current, pre: report }));
      setMessage(report.canProceed ? "Pre-signature check completed. Review all warnings and the original files." : "Pre-signature check found " + report.errors.length + " blocking issue(s).");
    } catch (e) { setError(e?.message || "Paperwork validation failed."); }
    finally { setBusy(false); }
  }

  function runPostCheck() {
    if (!selected) { setError("Select a trade first."); return; }
    const docs = files.map(item => ({ id: item.id, document_name: item.file.name, document_type: item.type, mime_type: item.file.type, match_status: "APPROVED" }));
    const report = validateOfferPostSignature({ form, docs, clientConfirmations: confirmations });
    setReports(current => ({ ...current, post: report }));
    setMessage(report.canProceed ? "Post-signature check passed for our client(s)." : "Post-signature check needs attention.");
  }

  return <div className="panel" style={{ maxWidth: 1180, margin: "0 auto" }}>
    <div className="paneltitle"><div><h2><FileCheck2 size={22} style={{ verticalAlign: "middle", marginRight: 8 }} />Paperwork Validation</h2>
      <p className="muted">Temporary document checks for residential purchases and sales, residential leases, and commercial transactions.</p></div>
      <button className="secondary" type="button" onClick={resetValidation}><RefreshCw size={15}/> Clear check</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 16 }}>
      <strong>Temporary review only</strong>
      <div className="muted">Files stay in this browser session for validation. They are not uploaded, saved, or attached to a trade. Clearing the check or leaving this page removes them from the tool.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}
    <label style={{ display: "grid", gap: 6, maxWidth: 680, marginBottom: 16 }}>
      <strong>Select trade</strong>
      <select value={tradeId} onChange={event => chooseTrade(event.target.value)}>
        <option value="">Choose a trade…</option>
        {trades.map(row => {
          const p = row.payload || {};
          const tradeNo = p.transaction_number || row.trade_number || "Trade number pending";
          const address = p.property_address || [p.street_number,p.street_name].filter(Boolean).join(" ");
          return <option key={row.id} value={row.id}>{tradeNo} · {address || "Address not entered"} · {row.status || "Draft"}</option>;
        })}
      </select>
    </label>
    {loading && <p className="muted">Loading trades…</p>}
    {!loading && !trades.length && <p className="muted">No trades are available for this account.</p>}
    {selected && <>
      <div style={{ border: "1px solid #e4e7ec", borderRadius: 8, padding: 12, marginBottom: 16 }}>
        <strong>{form.transaction_number || selected.trade_number || "Trade"}</strong>
        <div className="muted">{form.property_address || [form.street_number,form.street_name,form.city].filter(Boolean).join(", ")}</div>
        <div className="muted">{String(form.transaction_type || "BUY_SELL").toUpperCase() === "LEASE" ? "Lease" : "Purchase and sale"} · {String(form.market_segment || "RESIDENTIAL").toUpperCase() === "COMMERCIAL" ? "Commercial" : "Residential"} · {side}</div>
      </div>
      <h3>1. Add documents</h3>
      <p className="muted">Choose a document category for each file. PDF text extraction and OCR are used where possible.</p>
      <label className="secondary" style={{ display: "inline-flex", alignItems: "center", gap: 8, cursor: "pointer", marginBottom: 12 }}>
        <Upload size={16}/> Select files
        <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff,.doc,.docx" style={{ display: "none" }} onChange={event => { addFiles(event.target.files); event.target.value = ""; }}/>
      </label>
      {files.length > 0 && <div style={{ display: "grid", gap: 8, marginBottom: 16 }}>
        {files.map(item => <div key={item.id} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(160px,220px) auto", alignItems: "center", gap: 8, border: "1px solid #e4e7ec", borderRadius: 8, padding: 8 }}>
          <span style={{ display: "flex", alignItems: "center", gap: 7, minWidth: 0, overflowWrap: "anywhere" }}><FileText size={16}/>{item.file.name}</span>
          <select value={item.type} onChange={event => { setFiles(current => current.map(x => x.id === item.id ? { ...x, type: event.target.value } : x)); setReports({ pre: null, post: null }); }}>
            {types.map(([type,label]) => <option key={type} value={type}>{label}</option>)}
          </select>
          <button type="button" className="textbutton" aria-label={"Remove " + item.file.name} onClick={() => { setFiles(current => current.filter(x => x.id !== item.id)); setReports({ pre: null, post: null }); }}><Trash2 size={16}/></button>
        </div>)}
      </div>}
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 18 }}>
        <button className="primary" type="button" disabled={busy || !files.length} onClick={runPreCheck}>{busy ? "Checking…" : "Run Pre-Signature Check"}</button>
        <button className="secondary" type="button" disabled={busy || !files.some(item => item.type === "APS")} onClick={runPostCheck}>Run Post-Signature Check</button>
      </div>
      {reports.pre && <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 14, marginBottom: 14 }}>
        <h3 style={{ marginTop: 0 }}>Pre-signature results</h3>
        <strong style={{ color: reports.pre.canProceed ? "#167344" : "#b42318" }}>{reports.pre.canProceed ? "No blocking issues detected" : reports.pre.errors.length + " blocking issue(s) found"}</strong>
        <div className="muted">Checked {reports.pre.checkedDocuments} temporary file(s), {reports.pre.readableDocuments} readable by text extraction.</div>
        {[["Errors",reports.pre.errors,"#b42318"],["Warnings",reports.pre.warnings,"#946200"],["Passed",reports.pre.passed,"#167344"]].map(([heading,items,color]) => items.length > 0 && <div key={heading} style={{ marginTop: 10 }}><strong style={{ color }}>{heading}</strong>{items.map(item => <div key={item.code} style={{ marginTop: 6, fontSize: 13 }}><b>{item.title}:</b> {item.detail}</div>)}</div>)}
      </section>}
      {reports.post && <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 14 }}>
        <h3 style={{ marginTop: 0 }}>Post-signature results</h3>
        <strong style={{ color: reports.post.canProceed ? "#167344" : "#b42318" }}>{reports.post.canProceed ? "Our client signature review confirmed" : "Post-signature check needs attention"}</strong>
        <p className="muted">This check applies only to Dream Valley's represented client(s). Other-party signatures are outside its scope. You must visually inspect the signed original; the tool cannot authenticate signatures.</p>
        {postClients.map(client => <label key={client.id} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 9 }}>
          <input type="checkbox" checked={confirmations[client.id] === true} onChange={event => setConfirmations(current => ({ ...current, [client.id]: event.target.checked }))}/>
          <span>I visually checked {client.name}'s signature, all required initials, and signing dates.</span>
        </label>)}
        <button className="primary" type="button" style={{ marginTop: 12 }} onClick={runPostCheck}>Re-run Post-Signature Check</button>
        {[["Items to complete",reports.post.errors,"#b42318"],["Warnings",reports.post.warnings,"#946200"],["Confirmed",reports.post.passed,"#167344"]].map(([heading,items,color]) => items.length > 0 && <div key={heading} style={{ marginTop: 10 }}><strong style={{ color }}>{heading}</strong>{items.map(item => <div key={item.code} style={{ marginTop: 6, fontSize: 13 }}><b>{item.title}:</b> {item.detail}</div>)}</div>)}
      </section>}
    </>}
    <div style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 18, color: "#667085", fontSize: 12 }}><AlertCircle size={15}/> Validation is a review aid. Always inspect original documents and obtain legal or compliance review where required.</div>
  </div>;
}
