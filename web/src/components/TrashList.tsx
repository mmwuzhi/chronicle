import { useTranslation } from "react-i18next";
import type { CaptureBody } from "@/api";
import { fmtListTime } from "@/utils/format";
import { Markdown } from "@/components/Markdown";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Meta } from "@/components/ui/page";

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
  const { t, i18n } = useTranslation("captures");

  return (
    <ul className="m-0 flex list-none flex-col gap-2.5 p-0">
      {captures.map((capture) => {
        const text = captureText(capture);
        return (
          <Card
            asChild
            key={capture.id}
            className="flex items-start gap-3 p-3.5"
          >
            <li>
              <div className="min-w-0 flex-1">
                <Meta className="mb-2 flex gap-2 text-[10px]">
                  {capture.deletedAt && (
                    <span>
                      {t("trash.deletedAt", {
                        time: fmtListTime(capture.deletedAt, i18n.language),
                      })}
                    </span>
                  )}
                </Meta>
                {capture.mediaUrl && capture.mediaType === "image" && (
                  <img
                    src={capture.mediaUrl}
                    alt=""
                    className="mb-2.5 block max-h-60 max-w-full rounded-control"
                  />
                )}
                {text && <Markdown>{text}</Markdown>}
              </div>
              <div className="flex shrink-0 flex-col gap-1.5">
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onRestore(capture.id)}
                  disabled={restoringId === capture.id}
                >
                  {t("trash.restore")}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  className="text-danger hover:bg-danger-weak hover:text-danger-strong"
                  onClick={() => onPermanentDelete(capture.id)}
                  disabled={restoringId === capture.id}
                >
                  {t("trash.deletePermanently")}
                </Button>
              </div>
            </li>
          </Card>
        );
      })}
    </ul>
  );
}
