import { useTranslation } from "react-i18next";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";
import { CaptureCard } from "./CaptureCard";

interface CaptureFeedProps {
  captures: CaptureBody[];
  loading: boolean;
  hasMore: boolean;
  loadingMore: boolean;
  onLoadMore: () => void;
  onReclassify: (id: string, value: CaptureUpdateInputBodyClassifiedAs) => void;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => void;
  onSaveTranscript: (id: string, transcript: string) => void;
  onUseTranscript: (id: string, mode: "append" | "replace") => void;
  onRetryTranscription: (id: string) => void;
  onPromoteToTask: (rawText: string, captureId: string) => void;
}

export function CaptureFeed({
  captures,
  loading,
  hasMore,
  loadingMore,
  onLoadMore,
  ...cardActions
}: CaptureFeedProps): React.JSX.Element {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");

  if (loading) return <p className="ch-meta">{tc("loading")}</p>;
  if (captures.length === 0) {
    return (
      <div className="ch-empty">
        <p>{t("nothingHere")}</p>
      </div>
    );
  }

  return (
    <>
      <div className="ch-list">
        {captures.map((capture) => (
          <CaptureCard key={capture.id} c={capture} {...cardActions} />
        ))}
      </div>
      {hasMore && (
        <div className="ch-load-more">
          <button
            className="ch-btn"
            onClick={onLoadMore}
            disabled={loadingMore}
          >
            {loadingMore ? tc("loading") : t("loadMore")}
          </button>
        </div>
      )}
    </>
  );
}
