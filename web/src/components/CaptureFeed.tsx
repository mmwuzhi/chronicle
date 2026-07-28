import { useTranslation } from "react-i18next";
import type { CaptureBody } from "@/api";
import { CaptureCard } from "@/components/CaptureCard";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";
import { EmptyState, Meta } from "@/components/ui/page";

interface CaptureFeedProps {
  captures: CaptureBody[];
  loading: boolean;
  hasMore: boolean;
  loadingMore: boolean;
  masonry?: boolean;
  onLoadMore: () => void;
  onDelete: (id: string) => void;
  onSaveText: (id: string, text: string) => Promise<unknown>;
  onSaveTranscript: (id: string, transcript: string) => Promise<unknown>;
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
  masonry = false,
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
      <ul
        className={cn(
          "m-0 list-none p-0",
          masonry
            ? "ch-capture-masonry grid grid-cols-1 gap-3"
            : "flex flex-col gap-3",
        )}
      >
        {captures.map((capture) => (
          <CaptureCard
            key={capture.id}
            c={capture}
            masonry={masonry}
            {...cardActions}
          />
        ))}
      </ul>
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
