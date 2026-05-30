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

export function SearchModal({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const runSearch = useCallback((q: string) => {
    if (!q.trim()) {
      setResults(null);
      return;
    }
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
    (results.captures.length > 0 ||
      results.tasks.length > 0 ||
      results.logEntries.length > 0);

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-20 bg-black/40"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="bg-white rounded-xl shadow-2xl w-full max-w-xl mx-4 flex flex-col max-h-[70vh] overflow-hidden">
        <div className="flex items-center gap-3 px-4 py-3 border-b border-gray-100 shrink-0">
          <svg
            className="w-4 h-4 text-gray-400 flex-shrink-0"
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            viewBox="0 0 24 24"
          >
            <circle cx="11" cy="11" r="8" />
            <path d="m21 21-4.35-4.35" />
          </svg>
          <input
            ref={inputRef}
            value={query}
            onChange={onChange}
            placeholder={t("search.placeholder")}
            className="flex-1 text-sm outline-none"
          />
          {loading && <span className="text-xs text-gray-400">…</span>}
        </div>

        <div className="overflow-y-auto flex-1 min-h-0">
          {query && !loading && !hasResults && (
            <p className="px-4 py-6 text-sm text-gray-400 text-center">
              {t("search.noResults")}
            </p>
          )}

          {results && results.captures.length > 0 && (
            <Section label={t("search.captures")}>
              {results.captures.map((c) => (
                <ResultRow
                  key={c.id}
                  primary={c.rawText ?? "—"}
                  secondary={new Date(c.createdAt).toLocaleDateString()}
                  onClick={() => {
                    navigate({ to: "/captures" });
                    onClose();
                  }}
                />
              ))}
            </Section>
          )}

          {results && results.tasks.length > 0 && (
            <Section label={t("search.tasks")}>
              {results.tasks.map((task) => (
                <ResultRow
                  key={task.id}
                  primary={task.title}
                  secondary={task.status}
                  onClick={() => {
                    navigate({
                      to: "/tasks/$taskId",
                      params: { taskId: task.id },
                    });
                    onClose();
                  }}
                />
              ))}
            </Section>
          )}

          {results && results.logEntries.length > 0 && (
            <Section label={t("search.logEntries")}>
              {results.logEntries.map((e) => (
                <ResultRow
                  key={e.id}
                  primary={e.body}
                  secondary={new Date(e.createdAt).toLocaleDateString()}
                  onClick={() => {
                    navigate({ to: "/tasks" });
                    onClose();
                  }}
                />
              ))}
            </Section>
          )}
        </div>
      </div>
    </div>
  );
}

function Section({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="py-2">
      <p className="px-4 py-1 text-xs font-medium text-gray-400 uppercase tracking-wide">
        {label}
      </p>
      {children}
    </div>
  );
}

function ResultRow({
  primary,
  secondary,
  onClick,
}: {
  primary: string;
  secondary: string;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-gray-50 transition-colors"
    >
      <span className="text-sm flex-1 truncate">{primary}</span>
      <span className="text-xs text-gray-400 flex-shrink-0">{secondary}</span>
    </button>
  );
}
