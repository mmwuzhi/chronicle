import { useState, useEffect, useRef, useCallback } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { apiClient } from "../lib/axios";

interface SearchCapture {
  id: string;
  rawText: string | null;
  classifiedAs: string;
  createdAt: string;
}
interface SearchTask {
  id: string;
  title: string;
  status: string;
}
interface SearchLogEntry {
  id: string;
  body: string;
  createdAt: string;
}
interface SearchResults {
  captures: SearchCapture[];
  tasks: SearchTask[];
  logEntries: SearchLogEntry[];
}

const TaskIcon = () => (
  <svg width="15" height="15" fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path strokeLinecap="round" strokeLinejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
  </svg>
);
const CaptureIcon = () => (
  <svg width="15" height="15" fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Z" />
  </svg>
);
const NoteIcon = () => (
  <svg width="15" height="15" fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z" />
  </svg>
);
const SearchIcon = () => (
  <svg width="18" height="18" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
  </svg>
);
const XIcon = () => (
  <svg width="16" height="16" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
    <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
  </svg>
);

export function SearchModal({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => { inputRef.current?.focus(); }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const runSearch = useCallback((q: string) => {
    if (!q.trim()) { setResults(null); return; }
    setLoading(true);
    apiClient
      .get<SearchResults>("/search", { params: { q } })
      .then((r) => setResults(r.data))
      .catch(() => setResults(null))
      .finally(() => setLoading(false));
  }, []);

  const onChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const q = e.target.value;
    setQuery(q);
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => runSearch(q), 300);
  };

  const hasResults =
    results &&
    (results.captures.length > 0 || results.tasks.length > 0 || results.logEntries.length > 0);

  return (
    <div className="ch-searchwrap">
      <div className="scrim" onMouseDown={onClose} />
      <div className="ch-searchpanel">
        <div className="ch-searchbar">
          <SearchIcon />
          <input
            ref={inputRef}
            value={query}
            onChange={onChange}
            placeholder={t("search.placeholder")}
          />
          {loading && <span className="ch-meta">…</span>}
          <kbd>Esc</kbd>
          <button className="s-cancel" onClick={onClose}>{t("actions.cancel")}</button>
          <button className="ch-iconbtn s-close" onClick={onClose} aria-label="Close">
            <XIcon />
          </button>
        </div>

        <div className="ch-searchresults">
          {query && !loading && !hasResults && (
            <div className="ch-empty" style={{ padding: "32px 24px" }}>
              <p>{t("search.noResults")}</p>
            </div>
          )}

          {!query && (
            <div style={{ padding: "24px 11px", color: "var(--text-faint)", fontSize: "var(--fs-sm)", textAlign: "center" }}>
              {t("search.typeToSearch")}
            </div>
          )}

          {results && results.tasks.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.tasks")}</div>
              {results.tasks.map((task) => (
                <button
                  key={task.id}
                  className="ch-sresult"
                  style={{ width: "100%", border: "none", background: "none", textAlign: "left" }}
                  onClick={() => { navigate({ to: "/tasks/$taskId", params: { taskId: task.id } }); onClose(); }}
                >
                  <span className="s-ico"><TaskIcon /></span>
                  <span className="s-body">
                    <span className="s-title">{task.title}</span>
                    <span className="s-sub">{task.status}</span>
                  </span>
                </button>
              ))}
            </>
          )}

          {results && results.captures.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.captures")}</div>
              {results.captures.map((c) => (
                <button
                  key={c.id}
                  className="ch-sresult"
                  style={{ width: "100%", border: "none", background: "none", textAlign: "left" }}
                  onClick={() => { navigate({ to: "/captures" }); onClose(); }}
                >
                  <span className="s-ico"><CaptureIcon /></span>
                  <span className="s-body">
                    <span className="s-title">{c.rawText ?? "—"}</span>
                    <span className="s-sub">{new Date(c.createdAt).toLocaleDateString()}</span>
                  </span>
                </button>
              ))}
            </>
          )}

          {results && results.logEntries.length > 0 && (
            <>
              <div className="ch-sgroup">{t("search.logEntries")}</div>
              {results.logEntries.map((e) => (
                <button
                  key={e.id}
                  className="ch-sresult"
                  style={{ width: "100%", border: "none", background: "none", textAlign: "left" }}
                  onClick={() => { navigate({ to: "/tasks" }); onClose(); }}
                >
                  <span className="s-ico"><NoteIcon /></span>
                  <span className="s-body">
                    <span className="s-title">{e.body}</span>
                    <span className="s-sub">{new Date(e.createdAt).toLocaleDateString()}</span>
                  </span>
                </button>
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
