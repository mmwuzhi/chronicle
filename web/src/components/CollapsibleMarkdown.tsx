import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { Markdown } from "@/components/Markdown";

interface CollapsibleMarkdownProps {
  children: string;
  showMoreLabel: string;
  tone?: "surface" | "accent";
  onTaskChange?: (markdown: string) => Promise<unknown>;
}

export function CollapsibleMarkdown({
  children,
  showMoreLabel,
  tone = "surface",
  onTaskChange,
}: CollapsibleMarkdownProps): React.JSX.Element {
  const clipRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const [canExpand, setCanExpand] = useState(false);

  const measure = useCallback(() => {
    const clip = clipRef.current;
    const content = contentRef.current;
    if (!clip || !content) return;
    const overflows = content.scrollHeight > clip.clientHeight + 1;
    setCanExpand(overflows);
  }, []);

  useLayoutEffect(() => {
    measure();
    const clip = clipRef.current;
    const content = contentRef.current;
    if (!clip || !content || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(clip);
    observer.observe(content);
    return () => observer.disconnect();
  }, [children, measure]);

  return (
    <div className="ch-collapsible-markdown" data-tone={tone}>
      <div ref={clipRef} className="max-h-40 overflow-hidden">
        <div ref={contentRef}>
          <Markdown onTaskChange={onTaskChange}>{children}</Markdown>
        </div>
      </div>
      {canExpand && (
        <div className="relative flex justify-center pt-1">
          <span
            aria-hidden="true"
            className="ch-collapsible-markdown__fade pointer-events-none absolute inset-x-0 bottom-full h-12"
          />
          <span className="inline-flex min-h-8 items-center gap-1.5 rounded-control px-2 font-app text-caption font-semibold text-muted transition-colors group-hover:text-ink">
            {showMoreLabel}
            <svg
              viewBox="0 0 20 20"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              aria-hidden="true"
              className="size-3.5 -rotate-90"
            >
              <path
                d="m6 8 4 4 4-4"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </span>
        </div>
      )}
    </div>
  );
}
