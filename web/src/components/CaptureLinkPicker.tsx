import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { useFind } from "@/api";
import { Input } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";
import { fmtListTime, fmtPreciseDateTime } from "@/utils/format";

const SEARCH_LIMIT = 8;

export function CaptureLinkPicker({
  anchorId,
  linkedIds,
  onPick,
}: {
  anchorId: string;
  linkedIds: string[];
  onPick: (targetId: string) => Promise<void>;
}): React.JSX.Element {
  const { t, i18n } = useTranslation("captures");
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [pendingId, setPendingId] = useState<string | null>(null);
  const excludedIds = useMemo(
    () => new Set([anchorId, ...linkedIds]),
    [anchorId, linkedIds],
  );

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedQuery(query.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  const findQuery = useFind(
    { q: debouncedQuery, limit: SEARCH_LIMIT },
    { query: { enabled: debouncedQuery.length > 0 } },
  );
  const results = (findQuery.data?.items ?? []).filter(
    (item) => !excludedIds.has(item.id),
  );

  const pick = async (targetId: string) => {
    setPendingId(targetId);
    try {
      await onPick(targetId);
      setQuery("");
      setDebouncedQuery("");
    } catch {
      // The link mutation surfaces its error through the shared toast.
    } finally {
      setPendingId(null);
    }
  };

  return (
    <div className="mb-4 rounded-control border border-line bg-surface-2 p-3">
      <Input
        autoFocus
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder={t("related.searchPlaceholder")}
        aria-label={t("related.searchLabel")}
      />
      {findQuery.isFetching && (
        <Meta className="mt-2 block">{t("related.searching")}</Meta>
      )}
      {findQuery.error && (
        <Meta className="mt-2 block text-danger">
          {t("related.searchFailed")}
        </Meta>
      )}
      {debouncedQuery &&
        !findQuery.isFetching &&
        !findQuery.error &&
        results.length === 0 && (
          <Meta className="mt-2 block">{t("related.noSearchResults")}</Meta>
        )}
      {results.length > 0 && (
        <ul className="m-0 mt-2 flex list-none flex-col gap-1 p-0">
          {results.map((item) => (
            <li key={item.id}>
              <button
                type="button"
                className="flex w-full cursor-pointer items-baseline gap-2.5 rounded-control border-0 bg-transparent px-2.5 py-2 text-left text-inherit transition-colors hover:bg-tint focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-accent/20 disabled:cursor-wait disabled:opacity-50"
                disabled={pendingId !== null}
                onClick={() => void pick(item.id)}
              >
                <span
                  className="shrink-0 font-code text-[10px] text-faint"
                  title={fmtPreciseDateTime(item.createdAt, i18n.language)}
                >
                  {fmtListTime(item.createdAt, i18n.language)}
                </span>
                <span className="min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-small">
                  {item.content}
                </span>
                <span className="shrink-0 text-caption font-semibold text-accent-strong">
                  {pendingId === item.id
                    ? t("related.linking")
                    : t("related.link")}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
