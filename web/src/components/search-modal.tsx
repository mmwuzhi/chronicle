import { useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useFind, useListCapturePage } from "../api";
import type { CaptureBody } from "../api";
import { fmtDate } from "../utils/format";
import { EmptyState, Meta } from "./ui/page";

const resultClassName =
  "flex w-full cursor-pointer items-center gap-[11px] rounded-control border-0 bg-transparent px-[11px] py-[9px] text-left font-app text-inherit hover:bg-tint";
const resultIconClassName =
  "grid size-[30px] shrink-0 place-items-center rounded-control border border-hairline bg-surface-2 text-muted";
const resultBodyClassName = "flex min-w-0 flex-1 flex-col";
const resultTitleClassName =
  "block max-w-full overflow-hidden text-ellipsis whitespace-nowrap text-small text-ink";
const resultSubClassName = "mt-px text-caption text-faint";

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
    <div className="fixed inset-0 z-80 flex flex-col">
      <div
        className="absolute inset-0 bg-ink/22 max-md:hidden"
        onMouseDown={onClose}
      />
      <div className="relative mx-auto mt-16 flex max-h-[calc(100%-120px)] w-[calc(100%-80px)] max-w-[600px] flex-col overflow-hidden rounded-card border border-line bg-surface shadow-overlay max-md:m-0 max-md:h-full max-md:max-h-full max-md:w-full max-md:max-w-none max-md:rounded-none max-md:border-0 max-md:shadow-none">
        <div className="flex shrink-0 items-center gap-3 border-b border-hairline px-4 py-[15px]">
          <SearchIcon />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("search.placeholder")}
            className="min-w-0 flex-1 border-0 bg-transparent font-app text-base text-ink outline-none placeholder:text-faint"
          />
          {isFetching && <Meta>…</Meta>}
          <kbd className="hidden shrink-0 rounded-[5px] border border-hairline bg-tint px-1.5 py-[3px] font-code text-[10px] text-faint md:inline">
            Esc
          </kbd>
          <button
            className="shrink-0 cursor-pointer border-0 bg-transparent px-1 py-1.5 font-app text-body font-semibold text-accent-strong md:hidden"
            onClick={onClose}
          >
            {t("actions.cancel")}
          </button>
        </div>
        <div className="overflow-y-auto p-[7px]">
          {debouncedQuery && !isFetching && !hasResults && (
            <EmptyState className="px-6 py-8">
              <p>{t("search.noResults")}</p>
            </EmptyState>
          )}
          {!debouncedQuery &&
            (recentCaptures.length > 0 ? (
              <>
                <div className="px-[11px] pb-[5px] pt-2.5 text-caption font-bold uppercase tracking-[0.08em] text-faint">
                  {t("search.recentCaptures")}
                </div>
                {recentCaptures.map((capture: CaptureBody) => (
                  <button
                    key={capture.id}
                    className={resultClassName}
                    onClick={() => openCapture(capture.id)}
                  >
                    <span className={resultIconClassName}>✦</span>
                    <span className={resultBodyClassName}>
                      <span className={resultTitleClassName}>
                        {capture.rawText ?? capture.transcript ?? "—"}
                      </span>
                      <span className={resultSubClassName}>
                        {fmtDate(capture.createdAt)}
                      </span>
                    </span>
                  </button>
                ))}
              </>
            ) : (
              <EmptyState className="px-6 py-8">
                <p>{t("search.typeToSearch")}</p>
              </EmptyState>
            ))}
          {captures.length > 0 && (
            <>
              <div className="px-[11px] pb-[5px] pt-2.5 text-caption font-bold uppercase tracking-[0.08em] text-faint">
                {t("search.captures")}
                {degraded && (
                  <Meta className="ml-2 font-normal">
                    {t("search.keywordFallback")}
                  </Meta>
                )}
              </div>
              {captures.map((item) => (
                <button
                  key={item.id}
                  className={resultClassName}
                  onClick={() => openCapture(item.id)}
                >
                  <span className={resultIconClassName}>✦</span>
                  <span className={resultBodyClassName}>
                    <span className={resultTitleClassName}>
                      {item.content || "—"}
                    </span>
                    {item.snippet && item.snippet !== item.content && (
                      <span className="mt-0.5 line-clamp-2 max-w-full overflow-hidden text-caption leading-[1.45] text-muted">
                        {item.snippet}
                      </span>
                    )}
                    <span className={resultSubClassName}>
                      {fmtDate(item.createdAt)}
                    </span>
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
