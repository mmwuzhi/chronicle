import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import type { CaptureBody } from "../api";
import { Markdown } from "./Markdown";
import { cn } from "../lib/cn";
import { Card } from "./ui/card";
import { Meta } from "./ui/page";

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

  useEffect(() => {
    anchorRef.current?.scrollIntoView({ block: "center" });
  }, [anchorIndex]);

  return (
    <div className="pb-8">
      {hasEarlier && (
        <p className="my-3 text-center text-caption text-faint">
          {t("context.earlier")}
        </p>
      )}
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
                  "after:bg-accent after:shadow-[0_0_0_4px_var(--accent-weak)]",
              )}
            >
              <Meta className="pt-2 text-right text-[10px] max-sm:pt-0 max-sm:text-left">
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
                  isAnchor && "border-accent/50 shadow-focus",
                )}
              >
                {isAnchor && (
                  <span className="mb-[9px] inline-flex rounded-full bg-accent-weak px-[7px] py-[3px] text-[10px] font-bold uppercase text-accent-strong">
                    {t("context.match")}
                  </span>
                )}
                <Meta className="mb-2 flex gap-2 text-[10px]">
                  <span>{capture.source}</span>
                </Meta>
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
      {hasLater && (
        <p className="my-3 text-center text-caption text-faint">
          {t("context.later")}
        </p>
      )}
    </div>
  );
}
