import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import type { CaptureBody } from "../api";
import { Markdown } from "./Markdown";

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
    <div className="ch-context-window">
      {hasEarlier && (
        <p className="ch-context-boundary">{t("context.earlier")}</p>
      )}
      <ol className="ch-context-timeline">
        {items.map((capture, index) => {
          const isAnchor = index === anchorIndex;
          return (
            <li
              key={capture.id}
              ref={isAnchor ? anchorRef : undefined}
              className={`ch-context-item${isAnchor ? " anchor" : ""}`}
            >
              <div className="ch-context-time">
                {new Date(capture.createdAt).toLocaleString(i18n.language, {
                  month: "short",
                  day: "numeric",
                  hour: "numeric",
                  minute: "2-digit",
                })}
              </div>
              <div className="ch-context-card">
                {isAnchor && (
                  <span className="ch-context-anchor-label">
                    {t("context.match")}
                  </span>
                )}
                <div className="ch-context-meta">
                  <span>{capture.source}</span>
                  <span>{capture.classifiedAs}</span>
                </div>
                {capture.mediaUrl && capture.mediaType === "image" && (
                  <img
                    src={capture.mediaUrl}
                    alt=""
                    className="ch-context-image"
                  />
                )}
                {capture.mediaUrl && capture.mediaType === "audio" && (
                  <audio
                    controls
                    src={capture.mediaUrl}
                    className="ch-context-audio"
                  />
                )}
                {capture.rawText && <Markdown>{capture.rawText}</Markdown>}
                {!capture.rawText && capture.transcript && (
                  <Markdown>{capture.transcript}</Markdown>
                )}
                {capture.rawText && capture.transcript && (
                  <div className="ch-context-transcript">
                    <span>{t("transcript.label")}</span>
                    <Markdown>{capture.transcript}</Markdown>
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ol>
      {hasLater && <p className="ch-context-boundary">{t("context.later")}</p>}
    </div>
  );
}
