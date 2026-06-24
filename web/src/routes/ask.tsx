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
      className="ch-card"
      onClick={() =>
        void navigate({
          to: "/captures/context",
          search: { anchorId: source.id },
        })
      }
      style={{
        display: "flex",
        gap: 10,
        padding: "10px 12px",
        textAlign: "left",
        cursor: "pointer",
        width: "100%",
      }}
    >
      <span
        style={{
          fontFamily: "var(--font-mono)",
          fontSize: "var(--fs-xs)",
          fontWeight: 700,
          color: "var(--accent)",
          flexShrink: 0,
        }}
      >
        [{source.n}]
      </span>
      <span
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 2,
          minWidth: 0,
        }}
      >
        <span
          style={{
            fontSize: "var(--fs-sm)",
            color: "var(--text)",
            overflow: "hidden",
            textOverflow: "ellipsis",
            display: "-webkit-box",
            WebkitLineClamp: 2,
            WebkitBoxOrient: "vertical",
          }}
        >
          {source.content}
        </span>
        <span style={{ fontSize: "var(--fs-xs)", color: "var(--text-faint)" }}>
          {fmtDate(source.createdAt)}
        </span>
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
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <h1 className="ch-title">{t("ask.title")}</h1>
          <p className="ch-meta">{t("ask.subtitle")}</p>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
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
            style={{ resize: "vertical", fontFamily: "inherit" }}
          />
          <div style={{ display: "flex", justifyContent: "flex-end" }}>
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
          <p
            style={{
              fontSize: "var(--fs-sm)",
              color: "#c2410c",
              marginTop: 16,
            }}
          >
            {t("ask.unavailable")}
          </p>
        )}

        {result &&
          !askMutation.isPending &&
          (result.answer.trim() === "" && sources.length === 0 ? (
            <p className="ch-meta" style={{ marginTop: 20 }}>
              {t("ask.noData")}
            </p>
          ) : (
            <div
              style={{
                marginTop: 20,
                display: "flex",
                flexDirection: "column",
                gap: 16,
              }}
            >
              <div className="ch-card" style={{ padding: "var(--pad)" }}>
                <Markdown>{result.answer}</Markdown>
              </div>
              {sources.length > 0 && (
                <div
                  style={{ display: "flex", flexDirection: "column", gap: 8 }}
                >
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
