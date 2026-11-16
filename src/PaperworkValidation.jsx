import { useEffect, useState } from "react";
import { AlertCircle, CheckCircle2, FileCheck2, FileText, RefreshCw, Trash2, Upload } from "lucide-react";

const TYPES = [["FORM","Form / Agreement"],["SCHEDULE","Schedule / Attachment"],["DISCLOSURE","Disclosure"],["ID","Identity Document"],["OTHER","Other"]];
const isPdf = file => /pdf/i.test(file?.type || "") || /\\.pdf$/i.test(file?.name || "");
const idFor = () => typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random();
const hasValue = value => value !== undefined && value !== null && String(value).trim() !== "" && String(value).trim() !== "Off";

export default function PaperworkValidation({ isActive = true }) {
  const [files, setFiles] = useState([]);
  const [analyses, setAnalyses] = useState({});
  const [reports, setReports] = useState({ pre: null, post: null });
  const [signatureChecks, setSignatureChecks] = useState({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  function resetValidation() {
    setFiles([]);
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
    setError("");
    setMessage("");
  }
  useEffect(() => { if (!isActive) resetValidation(); }, [isActive]);

  function addFiles(list) {
    const picked = Array.from(list || []);
    if (!picked.length) return;
    setFiles(current => [...current, ...picked.map(file => ({ id: idFor(), file, type: "FORM" }))]);
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
    setError("");
    setMessage("");
  }

  async function analyzePdf(file) {
    const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
    const workerUrl = (await import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url")).default;
    pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
      const page = await pdf.getPage(pageNumber);
      const content = await page.getTextContent();
      const text = (content.items || []).map(item => String(item.str || "").trim()).filter(Boolean).join(" ");
      const annotations = await page.getAnnotations({ intent: "display" });
      const fields = annotations.filter(item => item.subtype === "Widget").map(item => ({
        name: item.fieldName || item.alternativeText || "Unnamed field",
        type: item.fieldType || "Text",
        value: item.fieldValue,
        required: Boolean((Number(item.fieldFlags) || 0) & 2),
        rect: item.rect || null
      }));
      pages.push({ pageNumber, text, fields, hasText: text.trim().length > 0 });
    }
    pdf.destroy();
    return pages;
  }

  async function analyzeImage(file) {
    const { createWorker } = await import("tesseract.js");
    const worker = await createWorker("eng");
    try {
      const result = await worker.recognize(file);
      return [{ pageNumber: 1, text: String(result?.data?.text || ""), fields: [], hasText: Boolean(String(result?.data?.text || "").trim()) }];
    } finally { await worker.terminate(); }
  }

  async function runPreCheck() {
    if (!files.length) { setError("Upload one or more forms first."); return; }
    setBusy(true);
    setError("");
    setMessage("");
    setReports({ pre: null, post: null });
    try {
      const next = {};
      for (const item of files) {
        let pages = [];
        try {
          if (isPdf(item.file)) pages = await analyzePdf(item.file);
          else if (/^image\\//i.test(item.file.type) || /\\.(png|jpe?g|tiff?)$/i.test(item.file.name)) pages = await analyzeImage(item.file);
          else pages = [{ pageNumber: 1, text: "", fields: [], hasText: false, unsupported: true }];
        } catch (e) {
          pages = [{ pageNumber: 1, text: "", fields: [], hasText: false, unreadable: true, error: e?.message || "Could not read this file" }];
        }
        next[item.id] = pages;
      }
      setAnalyses(next);

      const errors = [];
      const warnings = [];
      const passed = [];
      files.forEach(item => {
        const pages = next[item.id] || [];
        const fileName = item.file.name;
        if (!pages.length || pages.every(page => !page.hasText && !page.fields.length)) {
          warnings.push({ code: item.id + "_manual", title: fileName + ": manual review required", detail: "No readable form fields or text were detected. Open the original and inspect every page." });
          return;
        }
        let requiredCount = 0;
        let blankRequired = 0;
        pages.forEach(page => {
          page.fields.filter(field => field.required).forEach(field => {
            requiredCount++;
            if (!hasValue(field.value)) {
              blankRequired++;
              errors.push({ code: item.id + "_" + page.pageNumber + "_" + field.name, title: fileName + " — page " + page.pageNumber + ": " + field.name + " is blank", detail: "This PDF field is marked as required and has no entered value." });
            }
          });
          page.fields.filter(field => field.type === "Sig").forEach(field => {
            if (!hasValue(field.value)) warnings.push({ code: item.id + "_sig_" + page.pageNumber + "_" + field.name, title: fileName + " — page " + page.pageNumber + ": signature field is empty", detail: "A digital signature field appears blank. Confirm whether this form is expected to be signed at this stage." });
          });
          if (!page.hasText && !page.fields.length) warnings.push({ code: item.id + "_page_" + page.pageNumber, title: fileName + " — page " + page.pageNumber + " needs visual review", detail: "The system could not read this page. Check the page for blank required sections, checkboxes and missing entries." });
        });
        if (requiredCount && blankRequired === 0) passed.push({ code: item.id + "_required", title: fileName + ": required PDF fields completed", detail: requiredCount + " required fillable field(s) contain values." });
        if (!requiredCount) warnings.push({ code: item.id + "_no_required", title: fileName + ": no machine-readable required fields found", detail: "This may be a flattened or printed form. The system cannot tell which blank lines are mandatory; review the original page by page." });
        if (pages.some(page => page.fields.some(field => field.type === "Btn"))) warnings.push({ code: item.id + "_checkbox", title: fileName + ": review checkboxes and selections", detail: "Confirm that every applicable checkbox, option and declaration has been selected. Unselected options may be intentional." });
      });
      const report = { errors, warnings, passed, checkedDocuments: files.length, totalPages: Object.values(next).reduce((sum, pages) => sum + pages.length, 0), canProceed: errors.length === 0 };
      setReports({ pre: report, post: null });
      setMessage(errors.length ? "The form check found " + errors.length + " blank required field(s)." : "The initial form check is complete. Review all warnings and visually inspect the original forms.");
    } catch (e) {
      setError(e?.message || "Paperwork validation failed.");
    } finally {
      setBusy(false);
    }
  }

  function runPostCheck() {
    if (!Object.keys(analyses).length) { setError("Run the form completion check first."); return; }
    const errors = [];
    const warnings = [];
    const passed = [];
    files.forEach(item => {
      const pages = analyses[item.id] || [];
      pages.forEach(page => {
        const key = item.id + ":" + page.pageNumber;
        if (signatureChecks[key] === true) {
          passed.push({ code: key, title: item.file.name + " — page " + page.pageNumber + ": signature review confirmed", detail: "You confirmed that the required signatures, initials and dates are present on this page." });
        } else {
          errors.push({ code: key, title: item.file.name + " — page " + page.pageNumber + ": signature review not confirmed", detail: "Inspect this page and confirm that all required parties have signed, initialled and dated the required fields." });
        }
        const emptyDigital = page.fields.filter(field => field.type === "Sig" && !hasValue(field.value));
        emptyDigital.forEach(field => warnings.push({ code: key + "_" + field.name, title: item.file.name + " — page " + page.pageNumber + ": empty digital signature field", detail: "The PDF contains an empty signature field named " + field.name + "." }));
      });
    });
    const report = { errors, warnings, passed, canProceed: errors.length === 0 };
    setReports(current => ({ ...current, post: report }));
    setMessage(errors.length ? "Post-signature review is incomplete. Check the pages listed below." : "You confirmed the required signature review for every uploaded page.");
  }

  const resultSection = (heading, report) => report && (
    <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 14, marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>{heading}</h3>
      <strong style={{ color: report.canProceed ? "#167344" : "#b42318" }}>{report.canProceed ? "No blocking issues detected" : report.errors.length + " item(s) need attention"}</strong>
      {report.checkedDocuments !== undefined && <div className="muted">Checked {report.checkedDocuments} document(s) across {report.totalPages} page(s).</div>}
      {[[ "Errors", report.errors, "#b42318" ],[ "Warnings", report.warnings, "#946200" ],[ "Passed", report.passed, "#167344" ]].map(([label, items, color]) => items.length > 0 && (
        <div key={label} style={{ marginTop: 10 }}><strong style={{ color }}>{label}</strong>{items.map(item => (
          <div key={item.code} style={{ marginTop: 7, fontSize: 13 }}><b>{item.title}:</b> {item.detail}</div>
        ))}</div>
      ))}
    </section>
  );

  return <div className="panel" style={{ maxWidth: 1180, margin: "0 auto" }}>
    <div className="paneltitle">
      <div><h2><FileCheck2 size={22} style={{ verticalAlign: "middle", marginRight: 8 }} />Paperwork Validation</h2>
        <p className="muted">Check that forms are completed before signing, then review signatures after signing. No trade selection is required.</p></div>
      <button className="secondary" type="button" onClick={resetValidation}><RefreshCw size={15}/> Clear check</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 16 }}>
      <strong>Temporary review only</strong>
      <div className="muted">Files and results stay in this browser session. They are not uploaded, saved, or attached to a trade. Clearing the check or leaving this page removes them.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}
    <h3>1. Upload the paperwork package</h3>
    <p className="muted">Upload multiple PDF forms or scanned page images together. Choose a category for each file if helpful.</p>
    <label className="secondary" style={{ display: "inline-flex", alignItems: "center", gap: 8, cursor: "pointer", marginBottom: 12 }}>
      <Upload size={16}/> Select multiple files
      <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff" style={{ display: "none" }} onChange={event => { addFiles(event.target.files); event.target.value = ""; }}/>
    </label>
    {files.length > 0 && <div style={{ display: "grid", gap: 8, marginBottom: 16 }}>
      {files.map(item => <div key={item.id} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(150px,210px) auto", alignItems: "center", gap: 8, border: "1px solid #e4e7ec", borderRadius: 8, padding: 8 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 7, minWidth: 0, overflowWrap: "anywhere" }}><FileText size={16}/>{item.file.name}</span>
        <select value={item.type} onChange={event => { setFiles(current => current.map(file => file.id === item.id ? { ...file, type: event.target.value } : file)); setAnalyses({}); setReports({ pre: null, post: null }); }}>
          {TYPES.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
        <button type="button" className="textbutton" aria-label={"Remove " + item.file.name} onClick={() => { setFiles(current => current.filter(file => file.id !== item.id)); setAnalyses({}); setReports({ pre: null, post: null }); }}><Trash2 size={16}/></button>
      </div>)}
    </div>}
    <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 18 }}>
      <button className="primary" type="button" disabled={busy || !files.length} onClick={runPreCheck}>{busy ? "Checking forms…" : "Check Form Completion"}</button>
      <button className="secondary" type="button" disabled={busy || !Object.keys(analyses).length} onClick={runPostCheck}>Run Post-Signature Check</button>
    </div>
    {resultSection("Pre-signature form completion results", reports.pre)}
    {resultSection("Post-signature review results", reports.post)}
    {analyses && Object.keys(analyses).length > 0 && <section style={{ border: "1px solid #e4e7ec", borderRadius: 8, padding: 14, marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>2. Review signatures after signing</h3>
      <p className="muted">Open each original page and confirm the required signatures, initials and dates are visibly present. The system can detect blank digital signature fields, but it cannot authenticate handwritten signatures or reliably detect ink signatures in flattened scans.</p>
      {files.map(item => <div key={item.id} style={{ marginTop: 12, paddingTop: 10, borderTop: "1px solid #e4e7ec" }}>
        <strong>{item.file.name}</strong>
        {(analyses[item.id] || []).map(page => {
          const key = item.id + ":" + page.pageNumber;
          return <label key={key} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 8 }}>
            <input type="checkbox" checked={signatureChecks[key] === true} onChange={event => setSignatureChecks(current => ({ ...current, [key]: event.target.checked }))}/>
            <span>Page {page.pageNumber}: I checked that all required signatures, initials and dates are present.</span>
          </label>;
        })}
      </div>)}
    </section>}
    <div style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 18, color: "#667085", fontSize: 12 }}><AlertCircle size={15}/> Automated checks can identify blank required fillable PDF fields. Flattened forms and handwritten entries still need visual review.</div>
  </div>;
}
