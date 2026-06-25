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
import { fmtShortDateTime } from "../utils/format";

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

/**
 * The "Related" surface for a single anchor capture: durable user-made links
 * (unlink with ✕) plus AI semantic suggestions (link with +). The /related
 * endpoint already excludes the anchor and anything already linked, so adding a
 * link makes that suggestion drop out — both queries are invalidated together.
 */
export function CaptureRelated({
  anchorId,
}: {
  anchorId: string;
}): React.JSX.Element {
  const { t } = useTranslation("captures");
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

  return (
    <section className="ch-related">
      <h2 className="ch-related-title">{t("related.title")}</h2>

      <div className="ch-related-group">
        <h3 className="ch-related-subtitle">{t("related.linked")}</h3>
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
                  <span className="ch-related-time">
                    {fmtShortDateTime(capture.createdAt)}
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
                  ✕
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
                  <span className="ch-related-time">
                    {fmtShortDateTime(capture.createdAt)}
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
                  + {t("related.link")}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
