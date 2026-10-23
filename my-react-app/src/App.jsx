import { useEffect, useRef, useState } from "react";
import heroImage from "./assets/hero.png";
import { imageDimensions, predictImage, validateImageFile } from "./api.js";
import "./App.css";

const GRADE_META = {
  Premium: { tone: "gold", label: "Premium", summary: "Top-grade grains with strong uniformity and visual quality." },
  "Well-Milled": { tone: "green", label: "Well milled", summary: "Cleanly milled grains with good consistency." },
  "Poor-Quality-Rice-Mix": { tone: "red", label: "Poor quality mix", summary: "Mixed or low-quality grains that need review." },
};

// Icon paths live outside the component so they are not rebuilt on every render.
const ICON_PATHS = {
  upload: "M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5M5 20h14",
  camera: "M6 8h1.8L9.5 6h5L16.2 8H18a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Zm6 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z",
  close: "m7 7 10 10M17 7 7 17",
  refresh: "M20 7v5h-5M4 17v-5h5M18.1 9A7 7 0 0 0 6.3 6.6L4 9m2 6a7 7 0 0 0 11.8 2.4L20 15",
  scan: "M7 4H5a1 1 0 0 0-1 1v2m13-3h2a1 1 0 0 1 1 1v2M7 20H5a1 1 0 0 1-1-1v-2m13 3h2a1 1 0 0 0 1-1v-2M7 12h10",
  alert: "M12 8v5m0 4h.01M10.3 4.3 2.7 17.5A1 1 0 0 0 3.6 19h16.8a1 1 0 0 0 .9-1.5L13.7 4.3a2 2 0 0 0-3.4 0Z",
};

const Icon = ({ name }) => (
  <svg className="icon" viewBox="0 0 24 24" aria-hidden="true">
    <path d={ICON_PATHS[name]} />
  </svg>
);

function App() {
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState(null);
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [dragging, setDragging] = useState(false);
  const inputRef = useRef(null);
  const requestRef = useRef(null);
  const selectionRef = useRef(0);

  useEffect(() => () => {
    requestRef.current?.abort();
    selectionRef.current++;
  }, []);

  useEffect(() => () => {
    if (preview) URL.revokeObjectURL(preview);
  }, [preview]);

  const processFile = async (selectedFile) => {
    if (!selectedFile || requestRef.current) return;
    const selection = ++selectionRef.current;
    const error = validateImageFile(selectedFile);
    setFile(null);
    setPreview(null);
    setResult(null);
    if (error) {
      setResult({ error });
      return;
    }
    try {
      imageDimensions(await selectedFile.arrayBuffer());
    } catch (error) {
      if (selection === selectionRef.current) setResult({ error: error.message || "Unable to read this image." });
      return;
    }
    if (selection !== selectionRef.current) return;
    setFile(selectedFile);
    setPreview(URL.createObjectURL(selectedFile));
    setResult(null);
  };

  const handleDrop = (event) => {
    event.preventDefault();
    setDragging(false);
    const dropped = event.dataTransfer.files[0];
    processFile(dropped);
  };

  const handlePredict = async () => {
    if (!file || requestRef.current) return;
    const controller = new AbortController();
    requestRef.current = controller;
    setLoading(true);
    setResult(null);

    try {
      const data = await predictImage(file, { signal: controller.signal });
      if (!controller.signal.aborted) setResult(data);
    } catch (error) {
      if (!controller.signal.aborted) setResult({ error: error.message || "Prediction failed. Please try again." });
    } finally {
      requestRef.current = null;
      if (!controller.signal.aborted) setLoading(false);
    }
  };

  const handleReset = () => {
    selectionRef.current++;
    setFile(null);
    setPreview(null);
    setResult(null);
    if (inputRef.current) inputRef.current.value = "";
  };

  const grade = result?.predicted_grade;
  const meta = GRADE_META[grade] || { tone: "neutral", label: grade, summary: "Classification completed." };
  const confidence = result?.confidence ? parseFloat(result.confidence) : 0;
  const confidenceTone = confidence >= 80 ? "good" : confidence >= 50 ? "warning" : "danger";

  return (
    <main className="app-shell">
      <section className="workspace" aria-label="Rice grade classifier">
        <aside className="intro-panel">
          <div className="brand-mark">RG</div>
          <div>
            <p className="eyebrow">CNN Rice Quality System</p>
            <h1>Rice Grade Classifier</h1>
            <p className="intro-copy">
              Upload a clear rice grain image and classify its milling grade with the
              trained model.
            </p>
          </div>

          <img className="hero-image" src={heroImage} alt="Close-up of rice grains" />

          <div className="checklist" aria-label="Image tips">
            <span>Clear lighting</span>
            <span>Single rice sample</span>
            <span>JPG, PNG, or WEBP</span>
          </div>
        </aside>

        <section className="tool-panel">
          <div className="panel-heading">
            <div>
              <p className="eyebrow">Image Input</p>
              <h2>Sample Upload</h2>
            </div>
            {file && <span className="file-chip">{file.name}</span>}
          </div>

          <button
            type="button"
            className={`upload-zone ${dragging ? "is-dragging" : ""} ${preview ? "has-preview" : ""}`}
            disabled={loading}
            onClick={() => !preview && inputRef.current?.click()}
            onDrop={handleDrop}
            onDragOver={(event) => {
              event.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
          >
            {preview ? (
              <>
                <img src={preview} alt="Selected rice sample" className="preview-image" />
                <span className="preview-shade" aria-hidden="true" />
              </>
            ) : (
              <span className="upload-prompt">
                <span className="upload-icon">
                  <Icon name="camera" />
                </span>
                <span className="upload-title">Drop an image here</span>
                <span className="upload-copy">or click to browse from your files</span>
              </span>
            )}
          </button>

          <input
            ref={inputRef}
            type="file"
            accept=".jpg,.jpeg,.png,.webp,image/jpeg,image/png,image/webp"
            disabled={loading}
            onChange={(event) => processFile(event.target.files[0])}
            className="hidden-input"
          />

          <div className="actions">
            <button
              type="button"
              className="button button-secondary"
              onClick={handleReset}
              disabled={loading || !preview}
            >
              <Icon name={preview ? "close" : "refresh"} />
              Clear
            </button>
            <button
              type="button"
              className="button button-primary"
              onClick={handlePredict}
              disabled={loading || !file}
            >
              {loading ? (
                <>
                  <span className="spinner" />
                  Analyzing
                </>
              ) : (
                <>
                  <Icon name="scan" />
                  Classify Grade
                </>
              )}
            </button>
          </div>
        </section>

        <section className="result-panel" aria-live="polite">
          <div className="panel-heading">
            <div>
              <p className="eyebrow">Model Output</p>
              <h2>Classification</h2>
            </div>
            <span className={`status-dot ${loading ? "is-active" : ""}`} />
          </div>

          {!result && !loading && (
            <div className="empty-state">
              <Icon name="upload" />
              <p>Select a rice image, then run classification to view the grade and confidence score.</p>
            </div>
          )}

          {loading && (
            <div className="loading-state">
              <span className="loader-ring" />
              <p>Reading grain patterns and preparing the prediction.</p>
            </div>
          )}

          {result?.error && (
            <div className="error-state">
              <Icon name="alert" />
              <p>{result.error}</p>
            </div>
          )}

          {result && !result.error && (
            <div className="result-stack">
              <div className={`grade-card tone-${meta.tone}`}>
                <span className="grade-kicker">Predicted Grade</span>
                <strong>{meta.label}</strong>
                <p>{meta.summary}</p>
              </div>

              <div className="metric-block">
                <div className="metric-row">
                  <span>Confidence</span>
                  <strong>{confidence}%</strong>
                </div>
                <div className="progress-track">
                  <span
                    className={`progress-fill tone-${confidenceTone}`}
                    style={{ width: `${confidence}%` }}
                  />
                </div>
              </div>

              {result.note && <p className="note">{result.note}</p>}
            </div>
          )}
        </section>
      </section>
    </main>
  );
}

export default App;
