import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  getListCaptureTokensQueryKey,
  useCreateCaptureToken,
  useListCaptureTokens,
  useRevokeCaptureToken,
} from "../../api";
import { fmtDate } from "../../utils/format";
import { Button } from "../ui/button";
import { Card } from "../ui/card";
import { Input } from "../ui/field";
import { Meta } from "../ui/page";

// Long-lived, create-only capture tokens for headless quick-capture clients
// (the iOS Action Button shortcut). The raw token is shown exactly once at
// creation — mirrors the recovery-code reveal pattern. Listing never returns
// the hash; revocation is server-side and immediate.
export function QuickCaptureTokenSection(): React.JSX.Element {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const { data, isLoading } = useListCaptureTokens();
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListCaptureTokensQueryKey() });

  const create = useCreateCaptureToken({ mutation: { onSuccess: invalidate } });
  const revoke = useRevokeCaptureToken({ mutation: { onSuccess: invalidate } });

  const [name, setName] = useState("");
  const [revealed, setRevealed] = useState<{
    name: string;
    token: string;
  } | null>(null);
  const [copied, setCopied] = useState(false);

  const submit = () => {
    if (!name.trim()) return;
    create.mutate(
      { data: { name: name.trim() } },
      {
        onSuccess: (res) => {
          setRevealed({ name: res.name, token: res.token });
          setCopied(false);
          setName("");
        },
      },
    );
  };

  const copy = async () => {
    if (!revealed) return;
    await navigator.clipboard.writeText(revealed.token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const tokens = data?.tokens ?? [];

  return (
    <Card asChild className="flex flex-col gap-4 p-4">
      <section>
        <div>
          <h2 className="font-app-display text-body font-semibold text-ink">
            {t("integrations.captureTokens.title")}
          </h2>
          <Meta>{t("integrations.captureTokens.description")}</Meta>
        </div>

        {revealed && (
          <Card className="flex flex-col gap-2 bg-tint p-4">
            <strong>{t("integrations.captureTokens.revealTitle")}</strong>
            <code className="break-all font-code text-small">
              {revealed.token}
            </code>
            <Meta>{t("integrations.captureTokens.revealHint")}</Meta>
            <Meta>{t("integrations.captureTokens.docHint")}</Meta>
            <div className="flex gap-2">
              <Button variant="primary" size="sm" onClick={copy}>
                {copied
                  ? t("integrations.captureTokens.copied")
                  : t("integrations.captureTokens.copy")}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setRevealed(null)}
              >
                {t("integrations.captureTokens.done")}
              </Button>
            </div>
          </Card>
        )}

        {isLoading ? (
          <Meta>{tc("loading")}</Meta>
        ) : tokens.length === 0 ? (
          <Meta>{t("integrations.captureTokens.empty")}</Meta>
        ) : (
          <ul className="m-0 flex list-none flex-col gap-2 p-0">
            {tokens.map((tok) => (
              <Card
                asChild
                key={tok.id}
                className="flex items-center gap-2 p-4"
              >
                <li>
                  <div className="min-w-0 flex-1">
                    <div className="font-semibold text-ink">{tok.name}</div>
                    <Meta className="block">
                      {t("integrations.captureTokens.created", {
                        date: fmtDate(tok.createdAt),
                      })}
                      {" · "}
                      {tok.lastUsedAt
                        ? t("integrations.captureTokens.lastUsed", {
                            date: fmtDate(tok.lastUsedAt),
                          })
                        : t("integrations.captureTokens.neverUsed")}
                    </Meta>
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => revoke.mutate({ id: tok.id })}
                  >
                    {t("integrations.captureTokens.revoke")}
                  </Button>
                </li>
              </Card>
            ))}
          </ul>
        )}

        <div className="flex flex-col gap-2">
          <Meta>{t("integrations.captureTokens.addTitle")}</Meta>
          <Input
            placeholder={t("integrations.captureTokens.namePlaceholder")}
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={100}
          />
          <Button
            variant="primary"
            onClick={submit}
            disabled={create.isPending || !name.trim()}
          >
            {t("integrations.captureTokens.generate")}
          </Button>
        </div>
      </section>
    </Card>
  );
}
