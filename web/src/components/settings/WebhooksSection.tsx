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
    <section
      className="ch-card"
      style={{ display: "flex", flexDirection: "column", gap: 16 }}
    >
      <div>
        <h2 className="ch-section-title">{t("integrations.webhooks.title")}</h2>
        <p className="ch-meta">{t("integrations.webhooks.description")}</p>
      </div>

      {isLoading ? (
        <p className="ch-meta">{tc("loading")}</p>
      ) : (webhooks ?? []).length === 0 ? (
        <p className="ch-meta">{t("integrations.webhooks.empty")}</p>
      ) : (
        <ul
          className="ch-list"
          style={{ display: "flex", flexDirection: "column", gap: 8 }}
        >
          {(webhooks ?? []).map((w) => (
            <li
              key={w.id}
              className="ch-row"
              style={{ display: "flex", alignItems: "center", gap: 8 }}
            >
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600 }}>{w.name}</div>
                <div className="ch-meta" style={{ wordBreak: "break-all" }}>
                  {w.targetUrl}
                </div>
              </div>
              <button className="ch-btn ch-btn-sm" onClick={() => toggle(w)}>
                {w.enabled
                  ? t("integrations.webhooks.disable")
                  : t("integrations.webhooks.enable")}
              </button>
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => remove.mutate({ id: w.id })}
              >
                {tc("actions.delete")}
              </button>
            </li>
          ))}
        </ul>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <h3 className="ch-meta">{t("integrations.webhooks.addTitle")}</h3>
        <input
          className="ch-input"
          placeholder={t("integrations.webhooks.name")}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <input
          className="ch-input"
          placeholder={t("integrations.webhooks.targetUrl")}
          value={targetUrl}
          onChange={(e) => setTargetUrl(e.target.value)}
        />
        <input
          className="ch-input"
          placeholder={t("integrations.webhooks.keywords")}
          value={keywords}
          onChange={(e) => setKeywords(e.target.value)}
        />
        <input
          className="ch-input"
          placeholder={t("integrations.webhooks.semanticQuery")}
          value={semanticQuery}
          onChange={(e) => setSemanticQuery(e.target.value)}
        />
        <textarea
          className="ch-textarea"
          placeholder={t("integrations.webhooks.payloadTemplate")}
          value={payloadTemplate}
          onChange={(e) => setPayloadTemplate(e.target.value)}
          rows={3}
        />
        <button
          className="ch-btn ch-btn-primary"
          onClick={submit}
          disabled={create.isPending}
        >
          {t("integrations.webhooks.add")}
        </button>
      </div>
    </section>
  );
}
