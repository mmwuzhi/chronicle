import { useTranslation } from "react-i18next";
import type { CaptureBody } from "../api";
import { fmtShortDateTime } from "../utils/format";
import { Markdown } from "./Markdown";

const SNIPPET_MAX = 280;

function captureText(capture: CaptureBody): string {
  const text = capture.rawText || capture.transcript || "";
  const trimmed = text.trim();
  if (trimmed.length <= SNIPPET_MAX) return trimmed;
  return trimmed.slice(0, SNIPPET_MAX).trimEnd() + "…";
}

interface TrashListProps {
  captures: CaptureBody[];
  restoringId: string | null;
  onRestore: (id: string) => void;
  onPermanentDelete: (id: string) => void;
}

export function TrashList({
  captures,
  restoringId,
  onRestore,
  onPermanentDelete,
}: TrashListProps): React.JSX.Element {
  const { t } = useTranslation("captures");

  return (
    <ul className="ch-trash-list">
      {captures.map((capture) => {
        const text = captureText(capture);
        return (
          <li key={capture.id} className="ch-trash-item">
            <div className="ch-trash-body">
              <div className="ch-trash-meta">
                {capture.deletedAt && (
                  <span>
                    {t("trash.deletedAt", {
                      time: fmtShortDateTime(capture.deletedAt),
                    })}
                  </span>
                )}
              </div>
              {capture.mediaUrl && capture.mediaType === "image" && (
                <img src={capture.mediaUrl} alt="" className="ch-trash-image" />
              )}
              {text && <Markdown>{text}</Markdown>}
            </div>
            <div className="ch-trash-actions">
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => onRestore(capture.id)}
                disabled={restoringId === capture.id}
              >
                {t("trash.restore")}
              </button>
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm ch-btn-danger"
                onClick={() => onPermanentDelete(capture.id)}
                disabled={restoringId === capture.id}
              >
                {t("trash.deletePermanently")}
              </button>
            </div>
          </li>
        );
      })}
    </ul>
  );
}
