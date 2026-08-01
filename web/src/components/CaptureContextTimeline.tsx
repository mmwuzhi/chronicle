import { useLayoutEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import type { CaptureBody } from "@/api";
import { Markdown } from "@/components/Markdown";
import { cn } from "@/lib/cn";
import { Card } from "@/components/ui/card";
import { Meta } from "@/components/ui/page";

interface CaptureContextTimelineProps {
  items: CaptureBody[];
  anchorIndex: number;
  hasEarlier: boolean;
  hasLater: boolean;
}

export function CaptureContextTimeline({
  items,
  anchorIndex,
  hasEarlier,
  hasLater,
}: CaptureContextTimelineProps): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const anchorRef = useRef<HTMLLIElement>(null);

  useLayoutEffect(() => {
    anchorRef.current?.scrollIntoView({ block: "center" });
  }, [anchorIndex]);

  return (
    <div className="pb-8">
      <TimelineDirection
        label={t("context.earlier")}
        arrow="↑"
        hasMore={hasEarlier}
      />
      <ol className="m-0 list-none p-0">
        {items.map((capture, index) => {
          const isAnchor = index === anchorIndex;
          return (
            <li
              key={capture.id}
              ref={isAnchor ? anchorRef : undefined}
              className={cn(
                "group relative grid grid-cols-[110px_minmax(0,1fr)] gap-4 pb-4 pt-2 before:absolute before:bottom-0 before:left-[119px] before:top-0 before:w-px before:bg-hairline after:absolute after:left-[115px] after:top-6 after:size-[9px] after:rounded-full after:border-2 after:border-page after:bg-faint max-sm:grid-cols-1 max-sm:gap-1 max-sm:pl-[18px] max-sm:before:left-1 max-sm:after:left-0 max-sm:after:top-[17px]",
                isAnchor &&
                  "py-6 before:w-[2px] before:bg-accent/25 after:left-[112px] after:top-[34px] after:size-[15px] after:border-[4px] after:border-accent after:bg-surface after:shadow-[0_0_0_5px_var(--accent-weak)] max-sm:pl-[22px] max-sm:before:left-[5px] max-sm:after:left-[-1px] max-sm:after:top-[27px]",
              )}
            >
              <Meta
                className={cn(
                  "pt-2 text-right text-[10px] max-sm:pt-0 max-sm:text-left",
                  isAnchor && "font-semibold text-accent-strong",
                )}
              >
                {new Date(capture.createdAt).toLocaleString(i18n.language, {
                  month: "short",
                  day: "numeric",
                  hour: "numeric",
                  minute: "2-digit",
                })}
              </Meta>
              <Card
                className={cn(
                  "relative min-w-0 p-[15px]",
                  isAnchor &&
                    "border-2 border-accent bg-surface p-[18px] shadow-overlay",
                )}
              >
                {isAnchor && (
                  <div className="mb-3 flex items-center justify-between gap-3 border-b border-hairline pb-3">
                    <span className="inline-flex items-center gap-2 text-[10px] font-bold uppercase tracking-[0.06em] text-accent-strong">
                      <span className="size-1.5 rounded-full bg-accent" />
                      {t("context.selected")}
                    </span>
                    <Meta className="text-[10px]">{capture.source}</Meta>
                  </div>
                )}
                {!isAnchor && (
                  <Meta className="mb-2 flex gap-2 text-[10px]">
                    <span>{capture.source}</span>
                  </Meta>
                )}
                {capture.mediaUrl && capture.mediaType === "image" && (
                  <img
                    src={capture.mediaUrl}
                    alt=""
                    className="mb-2.5 block max-h-[360px] max-w-full rounded-control"
                  />
                )}
                {capture.mediaUrl && capture.mediaType === "audio" && (
                  <audio
                    controls
                    src={capture.mediaUrl}
                    className="mb-2.5 w-full"
                  />
                )}
                {capture.rawText && <Markdown>{capture.rawText}</Markdown>}
                {!capture.rawText && capture.transcript && (
                  <Markdown>{capture.transcript}</Markdown>
                )}
                {capture.rawText && capture.transcript && (
                  <div className="mt-3 border-t border-hairline pt-2.5">
                    <span className="mb-1.5 block text-[10px] font-bold uppercase text-accent-strong">
                      {t("transcript.label")}
                    </span>
                    <Markdown>{capture.transcript}</Markdown>
                  </div>
                )}
              </Card>
            </li>
          );
        })}
      </ol>
      <TimelineDirection
        label={t("context.later")}
        arrow="↓"
        hasMore={hasLater}
      />
    </div>
  );
}

function TimelineDirection({
  label,
  arrow,
  hasMore,
}: {
  label: string;
  arrow: string;
  hasMore: boolean;
}): React.JSX.Element {
  return (
    <div className="grid grid-cols-[110px_minmax(0,1fr)] gap-4 py-2 max-sm:grid-cols-1 max-sm:gap-0 max-sm:pl-[22px]">
      <span className="text-right font-code text-[10px] font-semibold uppercase tracking-[0.08em] text-faint max-sm:text-left">
        {label}
      </span>
      <span className="flex items-center gap-2 font-code text-caption text-faint">
        <span
          className="grid size-5 place-items-center rounded-full border border-line bg-surface"
          aria-hidden="true"
        >
          {arrow}
        </span>
        {hasMore && <span aria-hidden="true">•••</span>}
      </span>
    </div>
  );
}
