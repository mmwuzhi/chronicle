import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useAsk } from "../api";
import type { AskSource } from "../api";
import { Nav } from "../components/nav";
import { Markdown } from "../components/Markdown";
import { fmtDate } from "../utils/format";
import { Button } from "../components/ui/button";
import { Card } from "../components/ui/card";
import { Textarea } from "../components/ui/field";
import { Meta, PageHeader, PageShell, PageTitle } from "../components/ui/page";

export const Route = createFileRoute("/ask")({ component: Ask });

function SourceCard({ source }: { source: AskSource }): React.JSX.Element {
  const navigate = useNavigate();
  return (
    <Card
      asChild
      className="flex w-full cursor-pointer gap-2.5 p-2.5 text-left hover:border-strong"
    >
      <button
        onClick={() =>
          void navigate({
            to: "/captures/context",
            search: { anchorId: source.id },
          })
        }
      >
        <span className="shrink-0 font-code text-caption font-bold text-accent">
          [{source.n}]
        </span>
        <span className="flex min-w-0 flex-col gap-0.5">
          <span className="line-clamp-2 overflow-hidden text-small text-ink">
            {source.content}
          </span>
          <span className="text-caption text-faint">
            {fmtDate(source.createdAt)}
          </span>
        </span>
      </button>
    </Card>
  );
}

function Ask(): React.JSX.Element {
  const { t } = useTranslation();
  const [question, setQuestion] = useState("");
  const askMutation = useAsk();
  const result = askMutation.data;
  const sources = result?.sources ?? [];

  const submit = () => {
    const q = question.trim();
    if (q) askMutation.mutate({ data: { question: q } });
  };

  return (
    <>
      <Nav />
      <PageShell className="pb-0">
        <PageHeader>
          <PageTitle>{t("ask.title")}</PageTitle>
          <Meta>{t("ask.subtitle")}</Meta>
        </PageHeader>

        <div className="flex flex-col gap-2">
          <Textarea
            className="resize-y"
            value={question}
            onChange={(e) => setQuestion(e.target.value)}
            onKeyDown={(e) => {
              if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
                e.preventDefault();
                submit();
              }
            }}
            placeholder={t("ask.placeholder")}
            rows={3}
          />
          <div className="flex justify-end">
            <Button
              variant="primary"
              size="sm"
              onClick={submit}
              disabled={askMutation.isPending || question.trim().length === 0}
            >
              {askMutation.isPending ? t("ask.thinking") : t("ask.button")}
            </Button>
          </div>
        </div>

        {askMutation.isError && (
          <p className="mt-4 text-small text-danger">{t("ask.unavailable")}</p>
        )}

        {result &&
          !askMutation.isPending &&
          (result.answer.trim() === "" && sources.length === 0 ? (
            <Meta className="mt-5 block">{t("ask.noData")}</Meta>
          ) : (
            <div className="mt-5 flex flex-col gap-4">
              <Card className="p-4">
                <Markdown>{result.answer}</Markdown>
              </Card>
              {sources.length > 0 && (
                <div className="flex flex-col gap-2">
                  <div className="px-[11px] pb-[5px] pt-2.5 text-caption font-bold uppercase tracking-[0.08em] text-faint">
                    {t("ask.sources")}
                  </div>
                  {sources.map((s) => (
                    <SourceCard key={s.id} source={s} />
                  ))}
                </div>
              )}
            </div>
          ))}
      </PageShell>
    </>
  );
}
