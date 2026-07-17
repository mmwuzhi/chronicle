import { useTranslation } from "react-i18next";
import type { CaptureBody } from "../api";
import { CaptureCard } from "./CaptureCard";
import { Button } from "./ui/button";
import { EmptyState, Meta } from "./ui/page";

interface CaptureFeedProps {
  captures: CaptureBody[];
  loading: boolean;
  hasMore: boolean;
  loadingMore: boolean;
  onLoadMore: () => void;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => void;
  onSaveTranscript: (id: string, transcript: string) => void;
  onUseTranscript: (capture: CaptureBody, mode: "append" | "replace") => void;
  onRetryTranscription: (id: string) => void;
  onSetRemind: (id: string, at: string | null, hide: boolean) => void;
  onMutationError: () => void;
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

  if (loading) return <Meta>{tc("loading")}</Meta>;
  if (captures.length === 0) {
    return (
      <EmptyState>
        <p>{t("nothingHere")}</p>
      </EmptyState>
    );
  }

  return (
    <>
      <div className="flex flex-col gap-3">
        {captures.map((capture) => (
          <CaptureCard key={capture.id} c={capture} {...cardActions} />
        ))}
      </div>
      {hasMore && (
        <div className="flex justify-center pb-2 pt-[18px]">
          <Button onClick={onLoadMore} disabled={loadingMore}>
            {loadingMore ? tc("loading") : t("loadMore")}
          </Button>
        </div>
      )}
    </>
  );
}
