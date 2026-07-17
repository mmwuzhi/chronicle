import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useFind, useListCapturePage } from "../api";
import type { CaptureBody } from "../api";
import { fmtDate } from "../utils/format";

const SearchIcon = () => (
  <svg
    width="18"
    height="18"
    fill="none"
    stroke="currentColor"
    strokeWidth={2}
    viewBox="0 0 24 24"
  >
    <circle cx="11" cy="11" r="8" />
    <path d="m21 21-4.35-4.35" />
  </svg>
);

export function SearchModal({
  onClose,
}: {
  onClose: () => void;
}): React.JSX.Element {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const { data: recentCapturePage } = useListCapturePage({ limit: 6 });
  // Semantic hybrid search over captures (/find). It self-degrades to keyword
  // FTS in the backend when the RAG sidecar is down — surfaced with a hint.
  const findQuery = useFind(
    { q: debouncedQuery, limit: 10 },
    { query: { enabled: debouncedQuery.length > 0 } },
  );
  const captures = findQuery.data?.items ?? [];
  const degraded = findQuery.data?.degraded ?? false;
  const hasResults = captures.length > 0;
  const isFetching = findQuery.isFetching;

  useEffect(() => inputRef.current?.focus(), []);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim()), 300);
    return () => window.clearTimeout(timer);
  }, [query]);
  useEffect(() => {
    const handleKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [onClose]);

  const openCapture = (id: string) => {
    void navigate({ to: "/captures/context", search: { anchorId: id } });
    onClose();
  };

  const recentCaptures = recentCapturePage?.items ?? [];

  return (
    <div className="ch-searchwrap">
      <div className="scrim" onMouseDown={onClose} />
      <div className="ch-searchpanel">
        <div className="ch-searchbar">
          <SearchIcon />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("search.placeholder")}
          />
          {isFetching && <span className="ch-meta">…</span>}
          <kbd>Esc</kbd>
          <button className="s-cancel" onClick={onClose}>
            {t("actions.cancel")}
          </button>
        </div>
        <div className="ch-searchresults">
          {debouncedQuery && !isFetching && !hasResults && (
            <div className="ch-empty ch-search-empty">
              <p>{t("search.noResults")}</p>
            </div>
          )}
          {!debouncedQuery &&
            (recentCaptures.length > 0 ? (
              <>
                <div className="ch-sgroup">{t("search.recentCaptures")}</div>
                {recentCaptures.map((capture: CaptureBody) => (
                  <button
                    key={capture.id}
                    className="ch-sresult"
                    onClick={() => openCapture(capture.id)}
                  >
                    <span className="s-ico">✦</span>
                    <span className="s-body">
                      <span className="s-title">
                        {capture.rawText ?? capture.transcript ?? "—"}
                      </span>
                      <span className="s-sub">
                        {fmtDate(capture.createdAt)}
                      </span>
                    </span>
                  </button>
                ))}
              </>
            ) : (
              <div className="ch-empty ch-search-empty">
                <p>{t("search.typeToSearch")}</p>
              </div>
            ))}
          {captures.length > 0 && (
            <>
              <div className="ch-sgroup">
                {t("search.captures")}
                {degraded && (
                  <span className="ch-meta ch-search-degraded">
                    {t("search.keywordFallback")}
                  </span>
                )}
              </div>
              {captures.map((item) => (
                <button
                  key={item.id}
                  className="ch-sresult"
                  onClick={() => openCapture(item.id)}
                >
                  <span className="s-ico">✦</span>
                  <span className="s-body">
                    <span className="s-title">{item.content || "—"}</span>
                    {item.snippet && item.snippet !== item.content && (
                      <span className="s-snippet">{item.snippet}</span>
                    )}
                    <span className="s-sub">{fmtDate(item.createdAt)}</span>
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
