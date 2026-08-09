import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTranslation } from "react-i18next";
import {
  getListCaptureSharesQueryKey,
  useCreateCaptureShare,
  useListCaptureShares,
  useRevokeCaptureShare,
  type CaptureBody,
  type CaptureShareBody,
  type CaptureShareCreateInputBodyExpiresIn,
} from "@/api";
import { Markdown } from "@/components/Markdown";
import { Button, type ButtonVariant } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { FieldError, FieldLabel, Input } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";
import { useConfirm } from "@/hooks/use-confirm";
import { buildCaptureShareURL, isCaptureShareExpired } from "@/utils/share";

export function CaptureShareDialog({
  capture,
  triggerVariant = "ghost",
  triggerClassName,
}: {
  capture: CaptureBody;
  triggerVariant?: ButtonVariant;
  triggerClassName?: string;
}): React.JSX.Element {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const { t: ts } = useTranslation("settings");
  const queryClient = useQueryClient();
  const confirm = useConfirm();
  const [open, setOpen] = useState(false);
  const [expiresIn, setExpiresIn] =
    useState<CaptureShareCreateInputBodyExpiresIn>("7d");
  const [createdShare, setCreatedShare] = useState<CaptureShareBody | null>(
    null,
  );
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState(false);
  const shares = useListCaptureShares(
    { captureId: capture.id, limit: 2 },
    { query: { enabled: open } },
  );
  const create = useCreateCaptureShare({
    mutation: {
      onSuccess: (created) => {
        setCreatedShare(created);
        setCopied(false);
        setError(false);
        void queryClient.invalidateQueries({
          queryKey: getListCaptureSharesQueryKey(),
        });
      },
      onError: () => setError(true),
    },
  });
  const revoke = useRevokeCaptureShare({
    mutation: {
      onSuccess: () => {
        setCreatedShare(null);
        setCopied(false);
        setError(false);
        void queryClient.invalidateQueries({
          queryKey: getListCaptureSharesQueryKey(),
        });
      },
      onError: () => setError(true),
    },
  });
  const persistedShare = (shares.data?.items ?? []).find(
    (item) => !isCaptureShareExpired(item.expiresAt),
  );
  const share =
    createdShare && !isCaptureShareExpired(createdShare.expiresAt)
      ? createdShare
      : persistedShare;
  const shareURL = share
    ? share.url || buildCaptureShareURL(share.id, share.secret)
    : null;
  const previewText = share?.snapshotRawText ?? capture.rawText ?? "";

  const copyLink = async (): Promise<void> => {
    if (!shareURL) return;
    try {
      await navigator.clipboard.writeText(shareURL);
      setCopied(true);
      setError(false);
    } catch {
      setError(true);
    }
  };

  const confirmRevoke = async (): Promise<void> => {
    if (!share) return;
    const accepted = await confirm({
      title: ts("data.shares.revokeTitle"),
      description: ts("data.shares.revokeDescription"),
      confirmLabel: ts("data.shares.revoke"),
      variant: "danger",
    });
    if (accepted) revoke.mutate({ id: share.id });
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(nextOpen) => {
        setOpen(nextOpen);
        if (nextOpen) setError(false);
      }}
    >
      <DialogTrigger asChild>
        <Button variant={triggerVariant} size="sm" className={triggerClassName}>
          {t("share.action")}
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-[480px] gap-5">
        <div className="flex flex-col gap-1.5">
          <DialogTitle>{t("share.title")}</DialogTitle>
          <DialogDescription>{t("share.description")}</DialogDescription>
        </div>

        <section className="flex flex-col gap-2">
          <p className="text-caption font-bold uppercase tracking-[0.08em] text-faint">
            {t("share.preview")}
          </p>
          <div className="max-h-48 overflow-y-auto rounded-card bg-tint p-4 shadow-[inset_0_0_0_1px_var(--border)]">
            <Markdown publicSafe>{previewText}</Markdown>
          </div>
          <Meta className="block text-pretty">{t("share.textOnly")}</Meta>
        </section>

        {shares.isLoading && !createdShare && <Meta>{t("share.loading")}</Meta>}

        {shares.error && !createdShare && (
          <FieldError>{ts("data.shares.loadFailed")}</FieldError>
        )}

        {!shares.isLoading && !shares.error && !share && (
          <div className="flex flex-col gap-2">
            <FieldLabel htmlFor={`share-expiry-${capture.id}`}>
              {t("share.expiry")}
            </FieldLabel>
            <select
              id={`share-expiry-${capture.id}`}
              value={expiresIn}
              onChange={(event) =>
                setExpiresIn(
                  event.currentTarget
                    .value as CaptureShareCreateInputBodyExpiresIn,
                )
              }
              className="min-h-10 w-full rounded-control border border-line bg-surface px-3 py-2 font-app text-body text-ink outline-none transition-[border-color,box-shadow] duration-150 focus:border-accent focus:shadow-focus"
            >
              <option value="1d">{t("share.expiry1d")}</option>
              <option value="7d">{t("share.expiry7d")}</option>
              <option value="30d">{t("share.expiry30d")}</option>
              <option value="never">{t("share.expiryNever")}</option>
            </select>
            {expiresIn === "never" && (
              <Meta className="block text-danger">
                {t("share.neverWarning")}
              </Meta>
            )}
            <Meta className="block">{t("share.replacesExisting")}</Meta>
          </div>
        )}

        {shareURL && (
          <div className="flex flex-col gap-2">
            <FieldLabel htmlFor={`share-link-${capture.id}`}>
              {t("share.link")}
            </FieldLabel>
            <Input
              id={`share-link-${capture.id}`}
              readOnly
              value={shareURL}
              className="font-code text-caption"
              onFocus={(event) => event.currentTarget.select()}
            />
          </div>
        )}

        {error && <FieldError>{t("share.failed")}</FieldError>}

        <div className="flex flex-wrap items-center justify-end gap-2">
          {shareURL ? (
            <>
              <Button
                variant="ghost"
                size="sm"
                disabled={revoke.isPending}
                className="mr-auto text-danger"
                onClick={() => void confirmRevoke()}
              >
                {ts("data.shares.revoke")}
              </Button>
              <DialogClose asChild>
                <Button variant="ghost" size="sm">
                  {t("share.done")}
                </Button>
              </DialogClose>
              <Button
                variant="primary"
                size="sm"
                onClick={() => void copyLink()}
              >
                {copied ? t("share.copied") : tc("actions.copy")}
              </Button>
            </>
          ) : (
            <>
              <DialogClose asChild>
                <Button variant="ghost" size="sm">
                  {tc("actions.cancel")}
                </Button>
              </DialogClose>
              <Button
                variant="primary"
                size="sm"
                disabled={create.isPending}
                onClick={() =>
                  create.mutate({
                    id: capture.id,
                    data: {
                      expiresIn,
                      snapshotRawText: capture.rawText ?? "",
                    },
                  })
                }
              >
                {create.isPending ? t("share.creating") : t("share.create")}
              </Button>
            </>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
