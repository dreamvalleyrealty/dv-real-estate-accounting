import { useEffect, useState } from "react";
import { AlertCircle, FileCheck2, FileText, RefreshCw, Trash2, Upload } from "lucide-react";
import { supabase } from "./lib/supabase";

const TYPES = [["FORM","Form / Agreement"],["SCHEDULE","Schedule / Attachment"],["DISCLOSURE","Disclosure"],["ID","Identity Document"],["OTHER","Other"]];
const isPdf = file => /pdf/i.test(file?.type || "") || /\\.pdf$/i.test(file?.name || "");
const idFor = () => typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random();
const hasValue = value => value !== undefined && value !== null && String(value).trim() !== "" && String(value).trim() !== "Off";
const normalize = value => String(value || "").toLowerCase().replace(/[^a-z0-9]/g, "");
const postSignatureRules = rules => (Array.isArray(rules) ? rules : []).filter(rule =>
  rule.required !== false && ["POST_SIGN","BOTH"].includes(String(rule.stage || "PRE_SIGN").toUpperCase()) &&
  ["SIGNATURE","INITIAL","DATE"].includes(String(rule.kind || "").toUpperCase())
);
const result = (code,title,detail) => ({ code,title,detail });

export default function PaperworkValidation({ isActive = true }) {
  const [files, setFiles] = useState([]);
  const [analyses, setAnalyses] = useState({});
  const [libraryForms, setLibraryForms] = useState([]);
  const [libraryError, setLibraryError] = useState("");
  const [reports, setReports] = useState({ pre: null, post: null });
  const [signatureChecks, setSignatureChecks] = useState({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    let live = true;
    async function loadLibrary() {
      if (!supabase) return;
      const { data, error: queryError } = await supabase.from("dv_accounting_paperwork_library")
        .select("id,document_name,category,version,effective_date,validation_rules")
        .eq("status","PUBLISHED").order("document_name",{ascending:true}).order("created_at",{ascending:false});
      if (!live) return;
      if (queryError) setLibraryError(queryError.message);
      else setLibraryForms(data || []);
    }
    loadLibrary();
    return () => { live = false; };
  }, []);

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
    setFiles(current => [...current, ...picked.map(file => ({ id: idFor(), file, type: "FORM", referenceId: "" }))]);
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
    let ocrWorker = null;
    try {
      for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
        const page = await pdf.getPage(pageNumber);
        const content = await page.getTextContent();
        let text = (content.items || []).map(item => String(item.str || "").trim()).filter(Boolean).join(" ");
        const annotations = await page.getAnnotations({ intent: "display" });
        const fields = annotations.filter(item => item.subtype === "Widget").map(item => ({
          name: item.fieldName || item.alternativeText || "Unnamed field",
          type: item.fieldType || "Text",
          value: item.fieldValue,
          required: Boolean((Number(item.fieldFlags) || 0) & 2)
        }));
        if (text.trim().length < 30) {
          if (!ocrWorker) {
            const { createWorker } = await import("tesseract.js");
            ocrWorker = await createWorker("eng");
          }
          const viewport = page.getViewport({ scale: 1.5 });
          const canvas = document.createElement("canvas");
          canvas.width = Math.ceil(viewport.width);
          canvas.height = Math.ceil(viewport.height);
          await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise;
          const scanned = await ocrWorker.recognize(canvas);
          const ocrText = String(scanned?.data?.text || "");
          if (ocrText.trim().length > text.trim().length) text = ocrText;
          canvas.width = 0;
          canvas.height = 0;
        }
        pages.push({ pageNumber, text, fields, hasText: text.trim().length > 0 });
      }
    } finally {
      if (ocrWorker) await ocrWorker.terminate();
      pdf.destroy();
    }
    return pages;
  }

  async function analyzeImage(file) {
    const { createWorker } = await import("tesseract.js");
    const worker = await createWorker("eng");
    try {
      const scanned = await worker.recognize(file);
      const text = String(scanned?.data?.text || "");
      return [{ pageNumber: 1, text, fields: [], hasText: Boolean(text.trim()) }];
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
        const fields = pages.flatMap(page => page.fields.map(field => ({ ...field, pageNumber: page.pageNumber })));
        if (!pages.length || pages.every(page => !page.hasText && !page.fields.length)) {
          warnings.push(result(item.id + "_manual",fileName + ": manual review required","No readable form fields or text were detected. Open the original and inspect every page."));
        }
        let requiredCount = 0;
        let blankRequired = 0;
        pages.forEach(page => {
          page.fields.filter(field => field.required && !["Sig"].includes(field.type)).forEach(field => {
            requiredCount++;
            if (!hasValue(field.value)) {
              blankRequired++;
              errors.push(result(item.id + "_" + page.pageNumber + "_" + field.name,fileName + " — page " + page.pageNumber + ": " + field.name + " is blank","This PDF field is marked as required and has no entered value."));
            }
          });
          page.fields.filter(field => field.type === "Sig" && !hasValue(field.value)).forEach(field =>
            warnings.push(result(item.id + "_sig_" + page.pageNumber + "_" + field.name,fileName + " — page " + page.pageNumber + ": signature field is empty","A digital signature field appears blank. Confirm whether this form is expected to be signed at this stage."))
          );
          if (!page.hasText && !page.fields.length) warnings.push(result(item.id + "_page_" + page.pageNumber,fileName + " — page " + page.pageNumber + " needs visual review","The system could not read this page. Check it for blank required sections, checkboxes and missing entries."));
        });
        if (requiredCount && blankRequired === 0) passed.push(result(item.id + "_required",fileName + ": required PDF fields completed",requiredCount + " required fillable field(s) contain values."));
        if (!requiredCount) warnings.push(result(item.id + "_no_required",fileName + ": manual completion review needed","This form has no machine-readable required fields. Use the reference checklist below and inspect the original page by page."));
        if (pages.some(page => page.fields.some(field => field.type === "Btn"))) warnings.push(result(item.id + "_checkbox",fileName + ": review checkboxes and selections","Confirm that every applicable checkbox, option and declaration has been selected. Unselected options may be intentional."));

        const reference = libraryForms.find(form => form.id === item.referenceId);
        if (reference) {
          const rules = Array.isArray(reference.validation_rules) ? reference.validation_rules : [];
          const preRules = rules.filter(rule => rule.required !== false && ["PRE_SIGN","BOTH"].includes(String(rule.stage || "PRE_SIGN").toUpperCase()) && !["SIGNATURE","INITIAL"].includes(String(rule.kind || "").toUpperCase()));
          if (!preRules.length) warnings.push(result(item.id + "_no_rules",fileName + ": no pre-signature rules configured","The selected library version has no pre-signature completion rules yet."));
          preRules.forEach((rule,index) => {
            const targetPage = Number(rule.page) > 0 ? Number(rule.page) : null;
            const key = normalize(rule.label);
            const matched = fields.filter(field => (!targetPage || field.pageNumber === targetPage) && key.length > 2 &&
              (normalize(field.name) === key || normalize(field.name).includes(key) || key.includes(normalize(field.name))));
            const code = item.id + "_rule_" + (rule.id || index);
            const location = targetPage ? "page " + targetPage : "the form";
            if (matched.length) {
              const empty = matched.every(field => !hasValue(field.value));
              if (empty && !rule.condition) errors.push(result(code,fileName + " — " + location + ": " + rule.label + " is blank","The library marks this item as required."));
              else if (empty) warnings.push(result(code,fileName + " — " + location + ": check " + rule.label,"This item is conditional (" + rule.condition + "). Confirm whether it applies and complete it if needed."));
              else passed.push(result(code,fileName + " — " + rule.label + " completed","The matching fillable PDF field contains a value."));
            } else {
              warnings.push(result(code,fileName + " — " + location + ": visually check " + rule.label,"The reference library expects this item" + (rule.condition ? " when " + rule.condition : "") + ". The uploaded PDF does not expose a matching fillable field, so confirm it on the original form."));
            }
          });
        } else if (libraryForms.length) {
          warnings.push(result(item.id + "_reference",fileName + ": reference form not selected","Select the matching official form from the Document Library to apply its completion checklist."));
        }
      });

      const report = { errors, warnings, passed, checkedDocuments: files.length, totalPages: Object.values(next).reduce((sum,pages) => sum + pages.length,0), canProceed: errors.length === 0 };
      setReports({ pre: report, post: null });
      setMessage(errors.length ? "The form check found " + errors.length + " blocking issue(s)." : "The initial form check is complete. Review warnings and visually inspect all required sections.");
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
      const reference = libraryForms.find(form => form.id === item.referenceId);
      const rules = postSignatureRules(reference?.validation_rules);
      if (rules.length) {
        rules.forEach((rule,index) => {
          const key = "rule:" + item.id + ":" + (rule.id || index);
          const label = rule.kind === "INITIAL" ? "initials" : rule.kind === "DATE" ? "signing date" : "signature";
          if (signatureChecks[key] === true) passed.push(result(key,item.file.name + " — page " + rule.page + ": " + rule.label + " confirmed","You confirmed the required " + label + " is present."));
          else errors.push(result(key,item.file.name + " — page " + rule.page + ": " + rule.label + " not confirmed","Inspect this page and confirm the required " + label + " is present and completed."));
        });
      } else {
        pages.forEach(page => {
          const key = item.id + ":" + page.pageNumber;
          if (signatureChecks[key] === true) passed.push(result(key,item.file.name + " — page " + page.pageNumber + ": signature review confirmed","You confirmed that required signatures, initials and dates are present on this page."));
          else errors.push(result(key,item.file.name + " — page " + page.pageNumber + ": signature review not confirmed","Inspect this page and confirm all required signatures, initials and dates are present."));
        });
        if (!reference) warnings.push(result(item.id + "_no_reference_post",item.file.name + ": no reference form selected","This post-signature review uses a page-by-page checklist because no library signature rules were selected."));
      }
    });
    const report = { errors, warnings, passed, canProceed: errors.length === 0 };
    setReports(current => ({ ...current, post: report }));
    setMessage(errors.length ? "Post-signature review is incomplete. Check the pages or signature fields listed below." : "You confirmed the required signature review for the uploaded forms.");
  }

  function setFileValue(id,patch) {
    setFiles(current => current.map(item => item.id === id ? { ...item, ...patch } : item));
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
  }

  const resultSection = (heading,report) => report && (
    <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 14, marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>{heading}</h3>
      <strong style={{ color: report.canProceed ? "#167344" : "#b42318" }}>{report.canProceed ? "No blocking issues detected" : report.errors.length + " item(s) need attention"}</strong>
      {report.checkedDocuments !== undefined && <div className="muted">Checked {report.checkedDocuments} document(s) across {report.totalPages} page(s).</div>}
      {[[ "Errors",report.errors,"#b42318" ],[ "Warnings",report.warnings,"#946200" ],[ "Passed",report.passed,"#167344" ]].map(([label,items,color]) => items.length > 0 && (
        <div key={label} style={{ marginTop: 10 }}><strong style={{ color }}>{label}</strong>{items.map(item => <div key={item.code} style={{ marginTop: 7, fontSize: 13 }}><b>{item.title}:</b> {item.detail}</div>)}</div>
      ))}
    </section>
  );

  return <div className="panel" style={{ maxWidth: 1180, margin: "0 auto" }}>
    <div className="paneltitle">
      <div><h2><FileCheck2 size={22} style={{ verticalAlign: "middle", marginRight: 8 }}/>Paperwork Validation</h2>
        <p className="muted">Check that forms are completed before signing, then review signatures after signing. No trade selection is required.</p></div>
      <button className="secondary" type="button" onClick={resetValidation}><RefreshCw size={15}/> Clear check</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 16 }}>
      <strong>Temporary review only</strong>
      <div className="muted">Completed paperwork and results stay in this browser session. They are not uploaded, saved, or attached to a trade. Only official blank reference forms and their rules are stored in the Document Library.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}
    <h3>1. Upload the paperwork package</h3>
    <p className="muted">Upload multiple PDF forms or scanned page images together. Select the matching official form for each document so the correct completion rules can be applied.</p>
    {libraryError && <p className="muted">The reference library could not be loaded: {libraryError}</p>}
    {!libraryForms.length && !libraryError && <p className="muted">No published reference forms are available yet. An administrator can add them in Document Library.</p>}
    <label className="secondary" style={{ display: "inline-flex", alignItems: "center", gap: 8, cursor: "pointer", marginBottom: 12 }}>
      <Upload size={16}/> Select multiple files
      <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.tif,.tiff" style={{ display: "none" }} onChange={event => { addFiles(event.target.files); event.target.value = ""; }}/>
    </label>
    {files.length > 0 && <div style={{ display: "grid", gap: 8, marginBottom: 16 }}>
      {files.map(item => <div key={item.id} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) minmax(170px,260px) minmax(150px,220px) auto", alignItems: "center", gap: 8, border: "1px solid #e4e7ec", borderRadius: 8, padding: 8 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 7, minWidth: 0, overflowWrap: "anywhere" }}><FileText size={16}/>{item.file.name}</span>
        <select aria-label="Document category" value={item.type} onChange={e => setFileValue(item.id,{type:e.target.value})}>{TYPES.map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select>
        <select aria-label="Reference form" value={item.referenceId} onChange={e => setFileValue(item.id,{referenceId:e.target.value})}>
          <option value="">Select reference form…</option>
          {libraryForms.map(form => <option key={form.id} value={form.id}>{form.document_name} · v{form.version}</option>)}
        </select>
        <button type="button" className="textbutton" aria-label={"Remove " + item.file.name} onClick={() => { setFiles(current => current.filter(file => file.id !== item.id)); setAnalyses({}); setReports({ pre: null, post: null }); }}><Trash2 size={16}/></button>
      </div>)}
    </div>}
    <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 18 }}>
      <button className="primary" type="button" disabled={busy || !files.length} onClick={runPreCheck}>{busy ? "Checking forms…" : "Check Form Completion"}</button>
      <button className="secondary" type="button" disabled={busy || !Object.keys(analyses).length} onClick={runPostCheck}>Run Post-Signature Check</button>
    </div>
    {resultSection("Pre-signature form completion results",reports.pre)}
    {resultSection("Post-signature review results",reports.post)}
    {Object.keys(analyses).length > 0 && <section style={{ border: "1px solid #e4e7ec", borderRadius: 8, padding: 14, marginBottom: 14 }}>
      <h3 style={{ marginTop: 0 }}>2. Review signatures after signing</h3>
      <p className="muted">Open each original page and confirm the required signatures, initials and dates are visibly present. The system can detect blank digital signature fields, but it cannot authenticate handwritten signatures or reliably detect ink signatures in flattened scans.</p>
      {files.map(item => {
        const pages = analyses[item.id] || [];
        const reference = libraryForms.find(form => form.id === item.referenceId);
        const rules = postSignatureRules(reference?.validation_rules);
        return <div key={item.id} style={{ marginTop: 12, paddingTop: 10, borderTop: "1px solid #e4e7ec" }}>
          <strong>{item.file.name}</strong>
          {rules.length ? rules.map((rule,index) => {
            const key = "rule:" + item.id + ":" + (rule.id || index);
            const kind = rule.kind === "INITIAL" ? "initials" : rule.kind === "DATE" ? "signing date" : "signature";
            return <label key={key} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 8 }}>
              <input type="checkbox" checked={signatureChecks[key] === true} onChange={e => setSignatureChecks(current => ({ ...current, [key]: e.target.checked }))}/>
              <span>Page {rule.page}: I confirmed the required {kind} for {rule.label} is present.</span>
            </label>;
          }) : pages.map(page => {
            const key = item.id + ":" + page.pageNumber;
            return <label key={key} style={{ display: "flex", alignItems: "flex-start", gap: 8, marginTop: 8 }}>
              <input type="checkbox" checked={signatureChecks[key] === true} onChange={e => setSignatureChecks(current => ({ ...current, [key]: e.target.checked }))}/>
              <span>Page {page.pageNumber}: I checked that all required signatures, initials and dates are present.</span>
            </label>;
          })}
        </div>;
      })}
    </section>}
    <div style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 18, color: "#667085", fontSize: 12 }}><AlertCircle size={15}/> The library tells the validator what to expect. Blank required fillable PDF fields can be detected automatically; flattened forms and handwritten entries still need visual review.</div>
  </div>;
}
