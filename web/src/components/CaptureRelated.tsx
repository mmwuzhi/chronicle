import { useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import {
  getListCaptureLinksQueryKey,
  getRelatedCapturesQueryKey,
  useAddCaptureLink,
  useListCaptureLinks,
  useRelatedCaptures,
  useRemoveCaptureLink,
  type CaptureBody,
} from "../api";
import { fmtListTime, fmtPreciseDateTime } from "../utils/format";
import { todoProgress } from "../utils/todo";
import { useTodoEnabled } from "../hooks/use-todo-enabled";
import { Button } from "./ui/button";
import { Meta } from "./ui/page";

const RELATED_LIMIT = 10;
const SNIPPET_MAX = 140;

function snippet(text: string | null | undefined): string {
  const trimmed = (text ?? "").trim();
  if (trimmed.length <= SNIPPET_MAX) return trimmed;
  return trimmed.slice(0, SNIPPET_MAX).trimEnd() + "…";
}

function captureText(capture: CaptureBody): string {
  return capture.rawText || capture.transcript || "";
}

function XIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path strokeLinecap="round" d="M18 6 6 18M6 6l12 12" />
    </svg>
  );
}

function PlusIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path strokeLinecap="round" d="M12 5v14M5 12h14" />
    </svg>
  );
}

/**
 * The "Related" surface for a single anchor capture: durable user-made links
 * (unlink with an X) plus AI semantic suggestions (link with a plus). The /related
 * endpoint already excludes the anchor and anything already linked, so adding a
 * link makes that suggestion drop out — both queries are invalidated together.
 */
export function CaptureRelated({
  anchorId,
}: {
  anchorId: string;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const enabled = anchorId.length > 0;

  const linksQuery = useListCaptureLinks(anchorId, {
    query: { enabled },
  });
  const relatedQuery = useRelatedCaptures(
    anchorId,
    { limit: RELATED_LIMIT },
    { query: { enabled } },
  );

  const invalidate = () => {
    void queryClient.invalidateQueries({
      queryKey: getListCaptureLinksQueryKey(anchorId),
    });
    void queryClient.invalidateQueries({
      queryKey: getRelatedCapturesQueryKey(anchorId),
    });
  };

  const addLink = useAddCaptureLink({ mutation: { onSuccess: invalidate } });
  const removeLink = useRemoveCaptureLink({
    mutation: { onSuccess: invalidate },
  });

  const linked = linksQuery.data ?? [];
  const suggestions = relatedQuery.data ?? [];
  const todosEnabled = useTodoEnabled();
  // Derived at read time from the linked captures — the lightweight "project"
  // view: an anchor capture plus its linked todos, never a stored aggregate.
  const progress = todoProgress(linked);

  return (
    <section className="mt-2 border-t border-hairline pt-5">
      <h2 className="mb-3 text-body font-semibold text-ink">
        {t("related.title")}
      </h2>

      <div className="mb-[18px]">
        <h3 className="mb-2 text-[10px] font-bold uppercase tracking-[0.04em] text-faint">
          {t("related.linked")}
          {todosEnabled && progress.total > 0 && (
            <span className="ml-2 text-caption font-normal text-muted">
              {t("related.todoProgress", {
                done: progress.done,
                total: progress.total,
              })}
            </span>
          )}
        </h3>
        {linked.length === 0 ? (
          <Meta>{t("related.none")}</Meta>
        ) : (
          <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
            {linked.map((capture) => (
              <li
                key={capture.id}
                className="flex items-center gap-2 rounded-control border border-line bg-surface px-2.5 py-2"
              >
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  className="flex min-w-0 flex-1 items-baseline gap-2.5 text-inherit no-underline hover:text-accent-strong"
                >
                  <span
                    className="shrink-0 font-code text-[10px] text-faint"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-small">
                    {snippet(captureText(capture))}
                  </span>
                </Link>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() =>
                    removeLink.mutate({ id: anchorId, targetId: capture.id })
                  }
                  disabled={removeLink.isPending}
                  aria-label={t("related.unlink")}
                  title={t("related.unlink")}
                >
                  <XIcon />
                </Button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="mb-[18px]">
        <h3 className="mb-2 text-[10px] font-bold uppercase tracking-[0.04em] text-faint">
          {t("related.suggestions")}
        </h3>
        {relatedQuery.isLoading ? (
          <Meta>{tc("loading")}</Meta>
        ) : suggestions.length === 0 ? (
          <Meta>{t("related.noSuggestions")}</Meta>
        ) : (
          <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
            {suggestions.map((capture) => (
              <li
                key={capture.id}
                className="flex items-center gap-2 rounded-control border border-line bg-surface px-2.5 py-2"
              >
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  className="flex min-w-0 flex-1 items-baseline gap-2.5 text-inherit no-underline hover:text-accent-strong"
                >
                  <span
                    className="shrink-0 font-code text-[10px] text-faint"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-small">
                    {snippet(capture.content)}
                  </span>
                </Link>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() =>
                    addLink.mutate({
                      id: anchorId,
                      data: { targetId: capture.id },
                    })
                  }
                  disabled={addLink.isPending}
                >
                  <PlusIcon />
                  {t("related.link")}
                </Button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
