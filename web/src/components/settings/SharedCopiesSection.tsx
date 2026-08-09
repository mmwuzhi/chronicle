import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCaptureSharesInfiniteQueryKey,
  getListCaptureSharesQueryKey,
  useListCaptureSharesInfinite,
  useRevokeCaptureShare,
} from "@/api";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { FieldError } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";
import { useConfirm } from "@/hooks/use-confirm";
import { fmtPreciseDateTime } from "@/utils/format";
import { buildCaptureShareURL, isCaptureShareExpired } from "@/utils/share";

export function SharedCopiesSection(): React.JSX.Element {
  const { t, i18n } = useTranslation("settings");
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [copiedID, setCopiedID] = useState<string | null>(null);
  const [error, setError] = useState(false);
  const query = useListCaptureSharesInfinite(
    { limit: 50 },
    {
      query: {
        initialPageParam: undefined,
        getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
      },
    },
  );
  const revoke = useRevokeCaptureShare({
    mutation: {
      onSuccess: () => {
        setError(false);
        void queryClient.invalidateQueries({
          queryKey: getListCaptureSharesQueryKey(),
        });
        void queryClient.invalidateQueries({
          queryKey: getListCaptureSharesInfiniteQueryKey(),
        });
      },
      onError: () => setError(true),
    },
  });
  const shares = query.data?.pages.flatMap((page) => page.items ?? []) ?? [];

  const copyLink = async (
    id: string,
    secret: string,
    canonicalURL: string,
  ): Promise<void> => {
    try {
      await navigator.clipboard.writeText(
        canonicalURL || buildCaptureShareURL(id, secret),
      );
      setCopiedID(id);
      setError(false);
    } catch {
      setError(true);
    }
  };

  const confirmRevoke = async (id: string): Promise<void> => {
    const accepted = await confirm({
      title: t("data.shares.revokeTitle"),
      description: t("data.shares.revokeDescription"),
      confirmLabel: t("data.shares.revoke"),
      variant: "danger",
    });
    if (accepted) revoke.mutate({ id });
  };

  return (
    <Card asChild className="flex flex-col gap-4 p-4">
      <section>
        <div>
          <h2 className="font-app-display text-body font-semibold text-ink">
            {t("data.shares.title")}
          </h2>
          <Meta>{t("data.shares.description")}</Meta>
        </div>

        {query.isLoading && <Meta>{t("common:loading")}</Meta>}
        {query.error && <FieldError>{t("data.shares.loadFailed")}</FieldError>}
        {!query.isLoading && !query.error && shares.length === 0 && (
          <Meta>{t("data.shares.empty")}</Meta>
        )}

        {shares.length > 0 && (
          <div className="divide-y divide-hairline">
            {shares.map((share) => {
              const expired = isCaptureShareExpired(share.expiresAt);
              return (
                <div
                  key={share.id}
                  className="flex flex-col gap-3 py-4 first:pt-1 last:pb-0 sm:flex-row sm:items-center"
                >
                  <div className="min-w-0 flex-1">
                    <p className="line-clamp-2 text-small leading-normal text-ink">
                      {share.snapshotRawText}
                    </p>
                    <Meta className="mt-1 block">
                      {expired
                        ? t("data.shares.expired")
                        : share.expiresAt
                          ? t("data.shares.expires", {
                              time: fmtPreciseDateTime(
                                share.expiresAt,
                                i18n.language,
                              ),
                            })
                          : t("data.shares.noExpiry")}
                    </Meta>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    {!expired && (
                      <Button
                        size="sm"
                        onClick={() =>
                          void copyLink(share.id, share.secret, share.url)
                        }
                      >
                        {copiedID === share.id
                          ? t("data.shares.copied")
                          : t("data.shares.copy")}
                      </Button>
                    )}
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={revoke.isPending}
                      onClick={() => void confirmRevoke(share.id)}
                    >
                      {t("data.shares.revoke")}
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {query.hasNextPage && (
          <Button
            variant="ghost"
            size="sm"
            disabled={query.isFetchingNextPage}
            className="mt-3"
            onClick={() => void query.fetchNextPage()}
          >
            {query.isFetchingNextPage
              ? t("common:loading")
              : t("data.shares.loadMore")}
          </Button>
        )}

        {error && <FieldError>{t("data.shares.actionFailed")}</FieldError>}
      </section>
    </Card>
  );
}
