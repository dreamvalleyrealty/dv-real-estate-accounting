import { useEffect, useRef, useState } from "react";
import { AlertCircle, FileCheck2, FileText, RefreshCw, Trash2, Upload } from "lucide-react";
import { supabase } from "./lib/supabase";

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
  const [showPostReview, setShowPostReview] = useState(false);
  const [aiAudit, setAiAudit] = useState({ loading: false, audit: null, error: "" });
  const [selectedFinding, setSelectedFinding] = useState(null);
  const [previewError, setPreviewError] = useState("");
  const previewCanvasRef = useRef(null);
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
    setShowPostReview(false);
    setAiAudit({ loading: false, audit: null, error: "" });
    setSelectedFinding(null);
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
    setShowPostReview(false);
    setAiAudit({ loading: false, audit: null, error: "" });
    setSelectedFinding(null);
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

  async function fileToBase64(file) {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return btoa(binary);
  }

  useEffect(() => {
    let cancelled = false;
    async function renderFindingPage() {
      if (!selectedFinding || !previewCanvasRef.current) return;
      const owner = files.find(item => item.file.name === selectedFinding.document_name);
      if (!owner || !isPdf(owner.file)) { setPreviewError("Preview is available for PDF documents. Open the uploaded image separately."); return; }
      try {
        setPreviewError("");
        const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
        const workerUrl = (await import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url")).default;
        pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;
        const pdf = await pdfjs.getDocument({ data: new Uint8Array(await owner.file.arrayBuffer()) }).promise;
        const pageNumber = Math.max(1, Math.min(Number(selectedFinding.page_number) || 1, pdf.numPages));
        const page = await pdf.getPage(pageNumber);
        const viewport = page.getViewport({ scale: 1.35 });
        const canvas = previewCanvasRef.current;
        if (!canvas || cancelled) { pdf.destroy(); return; }
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        await page.render({ canvasContext: canvas.getContext("2d"), viewport }).promise;
        pdf.destroy();
      } catch (e) {
        if (!cancelled) setPreviewError(e?.message || "Could not render this PDF page.");
      }
    }
    renderFindingPage();
    return () => { cancelled = true; };
  }, [selectedFinding, files]);

  function openFinding(finding) {
    setSelectedFinding(finding);
    setPreviewError("");
  }

  async function runAiAudit() {
    if (!supabase) throw new Error("The Back Office connection is unavailable.");
     const totalBytes = files.reduce((sum, item) => sum + item.file.size, 0);
    if (totalBytes > 4 * 1024 * 1024) {
      throw new Error("The AI review limit for this first release is 4 MB for the combined package. Reduce the file sizes or split the package.");
    }
    const uploaded = await Promise.all(files.map(async item => ({
      name: item.file.name,
      mimeType: item.file.type || (isPdf(item.file) ? "application/pdf" : ""),
      base64: await fileToBase64(item.file),
    })));
    const { data, error: invokeError } = await supabase.functions.invoke("ai-paperwork-audit", {
      body: { files: uploaded },
    });
    if (invokeError) throw new Error(invokeError.message || "AI review could not be completed.");
    if (data?.error) throw new Error(data.error);
    if (!data?.audit) throw new Error("The AI service returned an incomplete review.");
    setAiAudit({ loading: false, audit: data.audit, error: "" });
  }

  async function runPreCheck() {
    if (!files.length) { setError("Upload one or more forms first."); return; }
    setBusy(true);
    setError("");
    setMessage("");
    setReports({ pre: null, post: null });
    setAiAudit({ loading: true, audit: null, error: "" });
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
      await runAiAudit();
      setReports({ pre: null, post: null });
      setShowPostReview(false);
      setMessage("AI review finished. Follow the document-by-document findings below. Anything unreadable or unmatched requires manual review.");
      return;
      /* Legacy local field matching is intentionally disabled. The AI now identifies
         document boundaries first and applies only the matching published library rules. */
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
            const key = normalize(rule.field_key || rule.label);
            const matched = fields.filter(field => {
              const fieldKey = normalize(field.name);
              return (!targetPage || field.pageNumber === targetPage) && key.length > 2 && fieldKey.length > 2 &&
                (fieldKey === key || fieldKey.includes(key) || key.includes(fieldKey));
            });
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
        } else {
          warnings.push(result(item.id + "_reference",fileName + ": official reference form not selected","No matching published reference form was selected. The system cannot confirm that all form-specific requirements have been checked."));
        }
      });

      const status = errors.length ? "MISSING" : warnings.length ? "MANUAL_REVIEW" : "COMPLETE";
      const report = { errors, warnings, passed, status, checkedDocuments: files.length, totalPages: Object.values(next).reduce((sum,pages) => sum + pages.length,0), canProceed: status === "COMPLETE" };
      setReports({ pre: report, post: null });
      setShowPostReview(false);
      setMessage(errors.length ? "Some required items are missing. Correct them and run the check again." : warnings.length ? "The automated check is finished. Please complete the manual reviews listed below." : "The automated checks passed.");
      try {
        await runAiAudit();
      } catch (aiError) {
        setAiAudit({ loading: false, audit: null, error: aiError?.message || "AI review could not be completed." });
      }
    } catch (e) {
      setAiAudit({ loading: false, audit: null, error: "" });
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
    const status = errors.length ? "MISSING" : warnings.length ? "MANUAL_REVIEW" : "COMPLETE";
    const report = { errors, warnings, passed, status, canProceed: status === "COMPLETE" };
    setReports(current => ({ ...current, post: report }));
    setMessage(errors.length ? "Post-signature review is incomplete. Check the pages or signature fields listed below." : "You confirmed the required signature review for the uploaded forms.");
  }

  function setFileValue(id,patch) {
    setFiles(current => current.map(item => item.id === id ? { ...item, ...patch } : item));
    setAnalyses({});
    setReports({ pre: null, post: null });
    setSignatureChecks({});
    setShowPostReview(false);
  }

  const resultSection = (heading,report) => report && (
    <section style={{ border: "1px solid #d0d5dd", borderRadius: 8, padding: 16, margin: "14px 0" }}>
      <h3 style={{ marginTop: 0 }}>{heading}</h3>
      <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
        <strong style={{ color: report.status === "COMPLETE" ? "#167344" : report.status === "MISSING" ? "#b42318" : "#946200" }}>
          {report.status === "COMPLETE" ? "Complete" : report.status === "MISSING" ? "Missing information" : "Manual review required"}
        </strong>
        {report.checkedDocuments !== undefined && <span className="muted">· {report.checkedDocuments} document(s), {report.totalPages} page(s)</span>}
      </div>
      {[[ "Missing information",report.errors,"#b42318" ],[ "Please review",report.warnings,"#946200" ]].map(([label,items,color]) => items.length > 0 && (
        <div key={label} style={{ marginTop: 12 }}><strong style={{ color }}>{label}</strong>{items.map(item => {
          const owner = files.find(file => item.code.startsWith(file.id));
          const prefix = owner?.file?.name || "";
          const title = prefix && item.title.startsWith(prefix) ? item.title.slice(prefix.length).replace(/^\\s*[—:]\\s*/, "") : item.title;
          return <div key={item.code} style={{ marginTop: 7, padding: "8px 10px", background: "#f8f9fb", borderRadius: 6, fontSize: 13 }}><b>{title}</b><div className="muted">{item.detail}</div></div>;
        })}</div>
      ))}
      {report.passed.length > 0 && <div style={{ marginTop: 12, color: "#167344", fontSize: 13 }}><strong>{report.passed.length} check(s) completed</strong></div>}
    </section>
  );

  return <div className="panel" style={{ maxWidth: 980, margin: "0 auto" }}>
    <div className="paneltitle">
      <div><h2><FileCheck2 size={22} style={{ verticalAlign: "middle", marginRight: 8 }}/>Paperwork Validation</h2>
        <p className="muted">Check paperwork before signing. Review signatures after the documents are signed.</p></div>
      <button className="secondary" type="button" onClick={resetValidation}><RefreshCw size={15}/> Start over</button>
    </div>
    <div style={{ padding: 12, border: "1px solid #d6b979", borderRadius: 8, background: "#fffcf5", marginBottom: 20 }}>
      <strong>Temporary review with Google Gemini</strong>
      <div className="muted">Uploaded documents and results are not saved or attached to a trade by this application. The free Gemini API tier may use submitted content to improve Google products. Use dummy or redacted documents for testing. Do not upload confidential client paperwork through the free tier unless the brokerage has reviewed and approved Google’s data terms.</div>
    </div>
    {error && <div className="error" role="alert">{error}</div>}
    {message && <div className="notice" role="status">{message}</div>}

    <section style={{ border: "1px solid #e4e7ec", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
        <span style={{ background: "#0f2141", color: "#fff", borderRadius: 20, width: 28, height: 28, display: "inline-flex", alignItems: "center", justifyContent: "center", fontWeight: 700 }}>1</span>
        <h3 style={{ margin: 0 }}>Upload documents</h3>
      </div>
      <p className="muted">Upload the complete paperwork package as one or more PDFs. The system will identify individual documents and page ranges automatically, then match recognized forms to the published Document Library. The first AI review supports up to 4 MB combined per package.</p>
      {libraryError && <p className="error">The reference library could not be loaded: {libraryError}</p>}
      {!libraryForms.length && !libraryError && <div className="muted" style={{ padding: 10, background: "#f8f9fb", borderRadius: 6, marginBottom: 12 }}>No official reference forms are published yet. An administrator must publish reference forms in Document Library for automatic matching and form-specific checks.</div>}
      <label className="secondary" style={{ display: "inline-flex", alignItems: "center", gap: 8, cursor: "pointer", marginBottom: 12 }}>
        <Upload size={16}/> Choose files
        <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png,.webp" style={{ display: "none" }} onChange={event => { addFiles(event.target.files); event.target.value = ""; }}/>
      </label>
      {files.length > 0 && <div style={{ display: "grid", gap: 8, marginBottom: 14 }}>
        {files.map(item => <div key={item.id} style={{ display: "grid", gridTemplateColumns: "minmax(0,1fr) auto", alignItems: "center", gap: 10, border: "1px solid #e4e7ec", borderRadius: 8, padding: 10 }}>
          <span title={item.file.name} style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}><FileText size={18}/><span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.file.name}</span></span>
          <button type="button" className="textbutton" aria-label={"Remove " + item.file.name} onClick={() => { setFiles(current => current.filter(file => file.id !== item.id)); setAnalyses({}); setReports({ pre: null, post: null }); setShowPostReview(false); }}><Trash2 size={16}/></button>
        </div>)}
        <button className="primary" type="button" disabled={busy || !files.length} onClick={runPreCheck}>{busy ? "Checking documents and AI…" : "Run completion + AI check"}</button>
      </div>}
    </section>

    {resultSection("2. Form completion results",reports.pre)}
    {(aiAudit.loading || aiAudit.error || aiAudit.audit) && <section style={{ border: "1px solid #d0d5dd", borderRadius: 10, padding: 16, margin: "14px 0" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 9, marginBottom: 8 }}>
        <strong style={{ fontSize: 16 }}>AI paperwork review</strong>
        {aiAudit.loading && <span className="muted">Reviewing documents…</span>}
        {aiAudit.audit && <span className="muted">Google Gemini review</span>}
      </div>
      {aiAudit.loading && <p className="muted">Gemini is reading the uploaded pages and checking information across the package. Keep this page open.</p>}
      {aiAudit.error && <div className="notice" role="status">{aiAudit.error}</div>}
      {aiAudit.audit && <>
        <p style={{ marginTop: 0 }}>{aiAudit.audit.summary}</p>
        <div style={{ display: "grid", gap: 7, marginBottom: 12 }}>
          {(aiAudit.audit.documents || []).map((doc,index) => <div key={doc.document_name+index} style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "8px 10px", background: "#f8f9fb", borderRadius: 6 }}>
            <span style={{ minWidth: 0, overflowWrap: "anywhere" }}><strong>{doc.detected_type || "Document"}</strong><span className="muted"> · {doc.document_name}</span></span>
            <span className="muted" style={{ whiteSpace: "nowrap" }}>{doc.page_count ?? "?"} pages · {doc.review_status === "REVIEWED" ? "Reviewed" : doc.review_status === "PARTIAL" ? "Partial" : "Unreadable"}</span>
          </div>)}
        </div>
        {(aiAudit.audit.findings || []).length > 0 ? <div className="dv-paperwork-visual-review" style={{ display: "grid", gridTemplateColumns: selectedFinding ? "minmax(0, 1fr) minmax(0, 1.15fr)" : "1fr", gap: 16, alignItems: "start" }}><div style={{ display: "grid", gap: 8, minWidth: 0 }}>
          <strong>AI findings ({aiAudit.audit.findings.length})</strong>
          {aiAudit.audit.findings.map((finding,index) => {
            const color = finding.severity === "ERROR" ? "#b42318" : finding.severity === "WARNING" ? "#946200" : finding.severity === "INFO" ? "#167344" : "#475467";
            return <div key={index} style={{ border: "1px solid #e4e7ec", borderLeft: "3px solid "+color, borderRadius: 7, padding: 10 }}>
              <div style={{ display: "flex", justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
                <strong>{finding.title}</strong><span style={{ color, fontSize: 11, fontWeight: 700 }}>{finding.severity.replace("_"," ")} · {finding.confidence} CONFIDENCE</span>
              </div>
              <div className="muted" style={{ fontSize: 12, marginTop: 3 }}>{finding.document_name}{finding.page_number ? " · Page "+finding.page_number : ""}</div>
              <p style={{ margin: "7px 0", fontSize: 13 }}>{finding.explanation}</p>
              {finding.evidence && <div style={{ fontSize: 12, background: "#f8f9fb", padding: 7, borderRadius: 5 }}>Evidence: {finding.evidence}</div>}
              {finding.suggested_action && <div style={{ fontSize: 12, marginTop: 6 }}><strong>Suggested action:</strong> {finding.suggested_action}</div>}
              <button type="button" className="secondary" style={{ marginTop: 8, fontSize: 12 }} onClick={() => openFinding(finding)}>View location on form</button>
            </div>;
          })}
        </div> {selectedFinding && <section style={{ marginTop: 0, border: "1px solid #d0d5dd", borderRadius: 8, padding: 12, minWidth: 0, position: "sticky", top: 16 }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
            <div><strong>Form location preview</strong><div className="muted" style={{ fontSize: 12 }}>{selectedFinding.document_name} · Page {selectedFinding.page_number || 1}</div></div>
            <button type="button" className="secondary" onClick={() => setSelectedFinding(null)}>Close preview</button>
          </div>
          <p style={{ fontSize: 13 }}>{selectedFinding.title}: {selectedFinding.explanation}</p>
          {previewError && <div className="notice">{previewError}</div>}
          <div style={{ position: "relative", width: "100%", border: "1px solid #d0d5dd", marginTop: 8, background: "#f8f9fb" }}>
            <canvas ref={previewCanvasRef} style={{ display: "block", width: "100%", height: "auto" }}/>
            {selectedFinding.location && Number(selectedFinding.location.width) > 0 && Number(selectedFinding.location.height) > 0 ? <div style={{ position: "absolute", left: (Number(selectedFinding.location.x)||0)/10+"%", top: (Number(selectedFinding.location.y)||0)/10+"%", width: Math.min(100,Number(selectedFinding.location.width)/10)+"%", height: Math.min(100,Number(selectedFinding.location.height)/10)+"%", border: "3px solid #d92d20", background: "rgba(217,45,32,.14)", boxSizing: "border-box", pointerEvents: "none" }}/> : <div className="muted" style={{ padding: 10 }}>Gemini could not reliably locate this exact area. Use the page number and instructions to inspect the page manually.</div>}
          </div>
          <p className="muted" style={{ fontSize: 11 }}>The red box is an AI-estimated location, not a verified field boundary. Always confirm against the original form.</p>
        </section>}</div> : <div className="notice">AI did not identify any specific issues. This is not a legal approval; complete all required human checks.</div>}
        {(aiAudit.audit.findings || []).length > 0 && <style>{"@media (max-width: 760px) { .dv-paperwork-visual-review { grid-template-columns: minmax(0, 1fr) !important; } }"}</style>}
        {(aiAudit.audit.cross_document_checks || []).length > 0 && <div style={{ marginTop: 14 }}>
          <strong>Cross-document consistency</strong>
          {(aiAudit.audit.cross_document_checks || []).map((check,index) => <div key={index} style={{ padding: "8px 0", borderBottom: "1px solid #e4e7ec", fontSize: 13 }}>
            <strong>{check.field}</strong> · {check.result.replace("_"," ")}
            <div className="muted">{check.documents_compared.join(" / ")}</div>
            <div>{check.explanation}</div>
          </div>)}
        </div>}
        <p className="muted" style={{ fontSize: 11, marginBottom: 0 }}>AI findings are suggestions for human review, not legal advice or signature authentication. Uploaded files are sent to Google Gemini for processing and are not saved by this application. The Gemini free tier may use submitted content to improve Google products. Do not upload confidential client documents unless the applicable Google data terms have been reviewed and approved.</p>
      </>}
    </section>}
    {reports.pre && <section style={{ border: "1px solid #e4e7ec", borderRadius: 10, padding: 16, marginBottom: 16 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
        <span style={{ background: "#0f2141", color: "#fff", borderRadius: 20, width: 28, height: 28, display: "inline-flex", alignItems: "center", justifyContent: "center", fontWeight: 700 }}>3</span>
        <h3 style={{ margin: 0 }}>Review signatures after signing</h3>
      </div>
      <p className="muted">When the documents have been signed, open this review and check the required signatures, initials and dates. Handwritten signatures must be visually checked by a person.</p>
      {!showPostReview ? <button className="secondary" type="button" onClick={() => { setShowPostReview(true); setReports(current => ({ ...current, post: null })); }}>Start signature review</button> : <>
        {files.map(item => {
          const pages = analyses[item.id] || [];
          const reference = libraryForms.find(form => form.id === item.referenceId);
          const rules = postSignatureRules(reference?.validation_rules);
          const pageNumbers = [...new Set(rules.length ? rules.map(rule => Number(rule.page) || 1) : pages.map(page => page.pageNumber))].sort((a,b) => a-b);
          return <div key={item.id} style={{ marginTop: 14, paddingTop: 12, borderTop: "1px solid #e4e7ec" }}>
            <strong title={item.file.name} style={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.file.name}</strong>
            {pageNumbers.map(pageNumber => {
              const pageRules = rules.filter(rule => (Number(rule.page) || 1) === pageNumber);
              return <div key={pageNumber} style={{ marginTop: 9, padding: "9px 10px", background: "#f8f9fb", borderRadius: 6 }}>
                <strong style={{ fontSize: 13 }}>Page {pageNumber}</strong>
                {pageRules.length ? pageRules.map((rule,index) => {
                  const key = "rule:" + item.id + ":" + (rule.id || rules.indexOf(rule));
                  const kind = rule.kind === "INITIAL" ? "Initials" : rule.kind === "DATE" ? "Signing date" : "Signature";
                  return <label key={key} style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6, fontSize: 13 }}>
                    <input type="checkbox" checked={signatureChecks[key] === true} onChange={e => setSignatureChecks(current => ({ ...current, [key]: e.target.checked }))}/>
                    <span>{kind}: {rule.label}</span>
                  </label>;
                }) : <label style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6, fontSize: 13 }}>
                  <input type="checkbox" checked={signatureChecks[item.id + ":" + pageNumber] === true} onChange={e => setSignatureChecks(current => ({ ...current, [item.id + ":" + pageNumber]: e.target.checked }))}/>
                  <span>All required signatures, initials and dates are present</span>
                </label>}
              </div>;
            })}
          </div>;
        })}
        <div style={{ display: "flex", gap: 8, marginTop: 16, flexWrap: "wrap" }}>
          <button className="primary" type="button" disabled={busy} onClick={runPostCheck}>Complete signature review</button>
          <button className="secondary" type="button" onClick={() => { setShowPostReview(false); setReports(current => ({ ...current, post: null })); }}>Close review</button>
        </div>
        {resultSection("Signature review results",reports.post)}
      </>}
    </section>}
    <div className="muted" style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 14, fontSize: 12 }}><AlertCircle size={15}/> A result marked “Manual review required” is not a pass. Check the original document yourself. The system cannot confirm the authenticity of a signature.</div>
  </div>;
}
