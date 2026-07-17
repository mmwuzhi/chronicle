import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import {
  getListWebhooksQueryKey,
  useCreateWebhook,
  useDeleteWebhook,
  useListWebhooks,
  useUpdateWebhook,
  type WebhookBody,
} from "../../api";
import { Button } from "../ui/button";
import { Card } from "../ui/card";
import { Input, Textarea } from "../ui/field";
import { Meta } from "../ui/page";

// Manage capture webhooks: a capture matching a rule (keyword OR semantic) fires
// a templated POST to an external URL. Matching/delivery run in the ragsvc
// sidecar; this is the CRUD surface. Inline edit is intentionally omitted —
// delete and recreate — to keep the form simple; toggling enabled is supported.
export function WebhooksSection(): React.JSX.Element {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const queryClient = useQueryClient();
  const { data: webhooks, isLoading } = useListWebhooks();
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListWebhooksQueryKey() });

  const create = useCreateWebhook({ mutation: { onSuccess: invalidate } });
  const remove = useDeleteWebhook({ mutation: { onSuccess: invalidate } });
  const update = useUpdateWebhook({ mutation: { onSuccess: invalidate } });

  const [name, setName] = useState("");
  const [targetUrl, setTargetUrl] = useState("");
  const [keywords, setKeywords] = useState("");
  const [semanticQuery, setSemanticQuery] = useState("");
  const [payloadTemplate, setPayloadTemplate] = useState(
    '{"text":"[capture.text]"}',
  );

  const submit = () => {
    if (!name.trim() || !targetUrl.trim() || !payloadTemplate.trim()) return;
    create.mutate(
      {
        data: {
          name: name.trim(),
          targetUrl: targetUrl.trim(),
          keywords: keywords
            .split(",")
            .map((k) => k.trim())
            .filter(Boolean),
          semanticQuery: semanticQuery.trim() || undefined,
          payloadTemplate: payloadTemplate.trim(),
        },
      },
      {
        onSuccess: () => {
          setName("");
          setTargetUrl("");
          setKeywords("");
          setSemanticQuery("");
        },
      },
    );
  };

  const toggle = (w: WebhookBody) =>
    update.mutate({
      id: w.id,
      data: {
        name: w.name,
        targetUrl: w.targetUrl,
        keywords: w.keywords ?? [],
        semanticQuery: w.semanticQuery ?? undefined,
        semanticThreshold: w.semanticThreshold,
        payloadTemplate: w.payloadTemplate,
        enabled: !w.enabled,
      },
    });

  return (
    <Card asChild className="flex flex-col gap-4 p-4">
      <section>
        <div>
          <h2 className="font-app-display text-body font-semibold text-ink">
            {t("integrations.webhooks.title")}
          </h2>
          <Meta>{t("integrations.webhooks.description")}</Meta>
        </div>

        {isLoading ? (
          <Meta>{tc("loading")}</Meta>
        ) : (webhooks ?? []).length === 0 ? (
          <Meta>{t("integrations.webhooks.empty")}</Meta>
        ) : (
          <ul className="m-0 flex list-none flex-col gap-2 p-0">
            {(webhooks ?? []).map((w) => (
              <Card asChild key={w.id} className="flex items-center gap-2 p-4">
                <li>
                  <div className="min-w-0 flex-1">
                    <div className="font-semibold text-ink">{w.name}</div>
                    <Meta className="block break-all">{w.targetUrl}</Meta>
                  </div>
                  <Button size="sm" onClick={() => toggle(w)}>
                    {w.enabled
                      ? t("integrations.webhooks.disable")
                      : t("integrations.webhooks.enable")}
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => remove.mutate({ id: w.id })}
                  >
                    {tc("actions.delete")}
                  </Button>
                </li>
              </Card>
            ))}
          </ul>
        )}

        <div className="flex flex-col gap-2">
          <Meta>{t("integrations.webhooks.addTitle")}</Meta>
          <Input
            placeholder={t("integrations.webhooks.name")}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <Input
            placeholder={t("integrations.webhooks.targetUrl")}
            value={targetUrl}
            onChange={(e) => setTargetUrl(e.target.value)}
          />
          <Input
            placeholder={t("integrations.webhooks.keywords")}
            value={keywords}
            onChange={(e) => setKeywords(e.target.value)}
          />
          <Input
            placeholder={t("integrations.webhooks.semanticQuery")}
            value={semanticQuery}
            onChange={(e) => setSemanticQuery(e.target.value)}
          />
          <Textarea
            placeholder={t("integrations.webhooks.payloadTemplate")}
            value={payloadTemplate}
            onChange={(e) => setPayloadTemplate(e.target.value)}
            rows={3}
          />
          <Button
            variant="primary"
            onClick={submit}
            disabled={create.isPending}
          >
            {t("integrations.webhooks.add")}
          </Button>
        </div>
      </section>
    </Card>
  );
}
