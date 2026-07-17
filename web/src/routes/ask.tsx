import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useAsk } from "../api";
import type { AskSource } from "../api";
import { Nav } from "../components/nav";
import { Markdown } from "../components/Markdown";
import { fmtDate } from "../utils/format";

export const Route = createFileRoute("/ask")({ component: Ask });

function SourceCard({ source }: { source: AskSource }): React.JSX.Element {
  const navigate = useNavigate();
  return (
    <button
      className="ch-card ch-ask-source"
      onClick={() =>
        void navigate({
          to: "/captures/context",
          search: { anchorId: source.id },
        })
      }
    >
      <span className="ch-ask-source-number">[{source.n}]</span>
      <span className="ch-ask-source-body">
        <span className="ch-ask-source-content">{source.content}</span>
        <span className="ch-ask-source-date">{fmtDate(source.createdAt)}</span>
      </span>
    </button>
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
      <div className="ch-ask-page">
        <div className="ch-page-head">
          <h1 className="ch-title">{t("ask.title")}</h1>
          <p className="ch-meta">{t("ask.subtitle")}</p>
        </div>

        <div className="ch-ask-form">
          <textarea
            className="ch-textarea"
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
          <div className="ch-ask-submit">
            <button
              className="ch-btn ch-btn-primary ch-btn-sm"
              onClick={submit}
              disabled={askMutation.isPending || question.trim().length === 0}
            >
              {askMutation.isPending ? t("ask.thinking") : t("ask.button")}
            </button>
          </div>
        </div>

        {askMutation.isError && (
          <p className="ch-ask-error">{t("ask.unavailable")}</p>
        )}

        {result &&
          !askMutation.isPending &&
          (result.answer.trim() === "" && sources.length === 0 ? (
            <p className="ch-meta ch-ask-empty">{t("ask.noData")}</p>
          ) : (
            <div className="ch-ask-result">
              <div className="ch-card ch-ask-answer">
                <Markdown>{result.answer}</Markdown>
              </div>
              {sources.length > 0 && (
                <div className="ch-ask-sources">
                  <div className="ch-sgroup">{t("ask.sources")}</div>
                  {sources.map((s) => (
                    <SourceCard key={s.id} source={s} />
                  ))}
                </div>
              )}
            </div>
          ))}
      </div>
    </>
  );
}
