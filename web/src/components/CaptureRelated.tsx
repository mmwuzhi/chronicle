import { useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import {
  getListCaptureLinksQueryKey,
  getRelatedCapturesQueryKey,
  useAddCaptureLink,
  useListCaptureLinks,
  useRelatedCaptures,
  useRemoveCaptureLink,
} from "@/api";
import { truncateCaptureText } from "@/utils/capture";
import { fmtListTime, fmtPreciseDateTime } from "@/utils/format";
import { todoProgress } from "@/utils/todo";
import { useTodoEnabled } from "@/hooks/use-todo-enabled";
import { Button } from "@/components/ui/button";
import { Meta } from "@/components/ui/page";
import { CaptureLinkPicker } from "@/components/CaptureLinkPicker";

const RELATED_LIMIT = 10;
const SNIPPET_MAX = 140;

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

function LinkIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="m9.5 14.5 5-5m-7.3 8.3-1 1a3.54 3.54 0 0 1-5-5l3-3a3.54 3.54 0 0 1 5 0m7.6-4.6 1-1a3.54 3.54 0 0 1 5 5l-3 3a3.54 3.54 0 0 1-5 0"
      />
    </svg>
  );
}

function SparkIcon(): React.JSX.Element {
  return (
    <svg
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M12 3.5c.55 4.55 3.95 7.95 8.5 8.5-4.55.55-7.95 3.95-8.5 8.5-.55-4.55-3.95-7.95-8.5-8.5 4.55-.55 7.95-3.95 8.5-8.5Z"
      />
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
  onMutationError,
}: {
  anchorId: string;
  onMutationError: () => void;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const [pickerOpen, setPickerOpen] = useState(false);
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

  const addLink = useAddCaptureLink({
    mutation: { onSuccess: invalidate, onError: onMutationError },
  });
  const removeLink = useRemoveCaptureLink({
    mutation: { onSuccess: invalidate, onError: onMutationError },
  });

  const linked = linksQuery.data ?? [];
  const suggestions = relatedQuery.data ?? [];
  const todosEnabled = useTodoEnabled();
  // Derived at read time from the linked captures — the lightweight "project"
  // view: an anchor capture plus its linked todos, never a stored aggregate.
  const progress = todoProgress(linked);
  const loading = linksQuery.isLoading || relatedQuery.isLoading;
  const error = linksQuery.error || relatedQuery.error;

  return (
    <section className="mt-2 border-t border-hairline pt-4">
      <div className="flex items-center justify-between gap-4">
        <h2 className="m-0 flex items-center gap-2 text-body font-semibold text-ink [&_svg]:size-4">
          <LinkIcon />
          {t("related.title")}
        </h2>
        <Button
          variant="ghost"
          size="sm"
          aria-expanded={pickerOpen}
          onClick={() => setPickerOpen((open) => !open)}
        >
          <PlusIcon />
          {pickerOpen ? t("related.done") : t("related.add")}
        </Button>
      </div>

      {pickerOpen && (
        <div className="mt-3">
          <CaptureLinkPicker
            anchorId={anchorId}
            linkedIds={linked.map((capture) => capture.id)}
            onPick={async (targetId) => {
              await addLink.mutateAsync({
                id: anchorId,
                data: { targetId },
              });
              setPickerOpen(false);
            }}
          />
        </div>
      )}

      {loading && (
        <div
          className="mt-4 flex flex-col gap-2"
          role="status"
          aria-label={tc("loading")}
        >
          <span className="h-9 animate-pulse rounded-control bg-tint" />
          <span className="h-9 animate-pulse rounded-control bg-tint" />
        </div>
      )}

      {error && (
        <Meta className="mt-3 block text-danger">
          {t("related.failedToLoad")}
        </Meta>
      )}

      {!loading && !error && linked.length > 0 && (
        <div className="mt-4">
          <h3 className="mb-2 flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-[0.04em] text-faint [&_svg]:size-3.5">
            <LinkIcon />
            {t("related.linked")}
            {todosEnabled && progress.total > 0 && (
              <span className="ml-2 text-caption font-normal normal-case tracking-normal text-muted">
                {t("related.todoProgress", {
                  done: progress.done,
                  total: progress.total,
                })}
              </span>
            )}
          </h3>
          <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
            {linked.map((capture) => (
              <li
                key={capture.id}
                className="flex items-center gap-2 rounded-control border border-line bg-surface px-2.5 py-2 shadow-card"
              >
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  title={t("context.open")}
                  className="flex min-w-0 flex-1 items-baseline gap-2.5 text-inherit no-underline hover:text-accent-strong"
                >
                  <span
                    className="shrink-0 font-code text-[10px] text-faint"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-small">
                    {truncateCaptureText(capture, SNIPPET_MAX)}
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
        </div>
      )}

      {!loading && !error && suggestions.length > 0 && (
        <div className="mt-4 rounded-control border border-dashed border-strong bg-surface-2 p-3">
          <h3 className="mb-2 flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-[0.04em] text-faint [&_svg]:size-3.5">
            <SparkIcon />
            {t("related.suggestions")}
          </h3>
          <ul className="m-0 flex list-none flex-col gap-1.5 p-0">
            {suggestions.map((capture) => (
              <li
                key={capture.id}
                className="flex items-center gap-2 rounded-control bg-surface px-2.5 py-2"
              >
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  title={t("context.open")}
                  className="flex min-w-0 flex-1 items-baseline gap-2.5 text-inherit no-underline hover:text-accent-strong"
                >
                  <span
                    className="shrink-0 font-code text-[10px] text-faint"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-small">
                    {truncateCaptureText(
                      { rawText: capture.content, transcript: null },
                      SNIPPET_MAX,
                    )}
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
        </div>
      )}
    </section>
  );
}
