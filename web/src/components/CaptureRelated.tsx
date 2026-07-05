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
    <section className="ch-related">
      <h2 className="ch-related-title">{t("related.title")}</h2>

      <div className="ch-related-group">
        <h3 className="ch-related-subtitle">
          {t("related.linked")}
          {todosEnabled && progress.total > 0 && (
            <span className="ch-related-progress">
              {t("related.todoProgress", {
                done: progress.done,
                total: progress.total,
              })}
            </span>
          )}
        </h3>
        {linked.length === 0 ? (
          <p className="ch-meta">{t("related.none")}</p>
        ) : (
          <ul className="ch-related-list">
            {linked.map((capture) => (
              <li key={capture.id} className="ch-related-item">
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  className="ch-related-link"
                >
                  <span
                    className="ch-related-time"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="ch-related-snippet">
                    {snippet(captureText(capture))}
                  </span>
                </Link>
                <button
                  className="ch-btn ch-btn-ghost ch-btn-sm"
                  onClick={() =>
                    removeLink.mutate({ id: anchorId, targetId: capture.id })
                  }
                  disabled={removeLink.isPending}
                  aria-label={t("related.unlink")}
                  title={t("related.unlink")}
                >
                  <XIcon />
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="ch-related-group">
        <h3 className="ch-related-subtitle">{t("related.suggestions")}</h3>
        {relatedQuery.isLoading ? (
          <p className="ch-meta">{tc("loading")}</p>
        ) : suggestions.length === 0 ? (
          <p className="ch-meta">{t("related.noSuggestions")}</p>
        ) : (
          <ul className="ch-related-list">
            {suggestions.map((capture) => (
              <li key={capture.id} className="ch-related-item">
                <Link
                  to="/captures/context"
                  search={{ anchorId: capture.id }}
                  className="ch-related-link"
                >
                  <span
                    className="ch-related-time"
                    title={fmtPreciseDateTime(capture.createdAt, i18n.language)}
                  >
                    {fmtListTime(capture.createdAt, i18n.language)}
                  </span>
                  <span className="ch-related-snippet">
                    {snippet(capture.content)}
                  </span>
                </Link>
                <button
                  className="ch-btn ch-btn-ghost ch-btn-sm"
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
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
