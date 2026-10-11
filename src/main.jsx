import React, { Component } from "react";
import { createRoot } from "react-dom/client";
import App from "./App.jsx";
import "./styles.css";

class AppErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error) {
    return { error };
  }
  componentDidCatch(error, info) {
    console.error("DV Accounting render error:", error, info?.componentStack);
  }
  render() {
    if (this.state.error) {
      return (
        <div style={{ minHeight: "100vh", padding: "32px", background: "#f5f6f8", color: "#17233b", fontFamily: "system-ui, sans-serif" }}>
          <div style={{ maxWidth: 900, margin: "40px auto", padding: 28, background: "#fff", border: "1px solid #e6e9ee", borderRadius: 12 }}>
            <h1 style={{ color: "#0f2141" }}>DV Accounting could not load</h1>
            <p>The application encountered a runtime error. Copy the details below and send them to support.</p>
            <pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", padding: 16, background: "#f5f6f8", borderRadius: 8 }}>{String(this.state.error?.stack || this.state.error?.message || this.state.error)}</pre>
            <button onClick={() => window.location.reload()} style={{ padding: "10px 16px", background: "#9e8556", color: "#fff", border: 0, borderRadius: 6, cursor: "pointer" }}>Reload application</button>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(
    <React.StrictMode>
      <AppErrorBoundary>
        <App />
      </AppErrorBoundary>
    </React.StrictMode>
  );
} else {
  document.body.innerHTML = "<p style='font-family:system-ui;padding:32px'>DV Accounting could not start: the #root element is missing from index.html.</p>";
}
