import { createFileRoute, Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useGetMe, useListCapturePage } from "../api";
import type { CaptureBody } from "../api";

import { Nav } from "../components/nav";
import { timeAgo } from "../utils/format";

export const Route = createFileRoute("/")({ component: Index });

function Dashboard() {
  const { t, i18n } = useTranslation("dashboard");

  const { data: me } = useGetMe();
  const { data: capturePage } = useListCapturePage(
    { limit: 8 },
    { query: { enabled: !!me } },
  );
  const recentCaptures = capturePage?.items ?? [];

  const now = new Date();
  const dayName = now
    .toLocaleDateString(undefined, { weekday: "long" })
    .toUpperCase();
  const monthDay = now
    .toLocaleDateString(undefined, { month: "short", day: "numeric" })
    .toUpperCase();
  const dateEyebrow = `${dayName} · ${monthDay}`;

  const hour = now.getHours();
  const greetingKey =
    hour < 12 ? "goodMorning" : hour < 17 ? "goodAfternoon" : "goodEvening";
  const name = me?.email?.split("@")[0] ?? "";

  return (
    <>
      <Nav />
      <div style={{ maxWidth: 768, margin: "0 auto", padding: "0 18px" }}>
        <div className="ch-page-head">
          <p className="ch-eyebrow">{dateEyebrow}</p>
          <h1 className="ch-title">
            {t(greetingKey)} {name}
          </h1>
        </div>

        <div className="ch-section">
          <span className="bar" />
          <span className="ch-sectlabel">{t("recentCaptures")}</span>
          <span className="ch-sectcount">{recentCaptures.length}</span>
          <span className="rule" />
          <Link to="/captures" className="ch-sectall">
            {t("viewAll")} →
          </Link>
        </div>
        {recentCaptures.length === 0 ? (
          <div className="ch-empty">
            <p>{t("noCaptures")}</p>
          </div>
        ) : (
          <div className="ch-list">
            {recentCaptures.map((c: CaptureBody) => (
              <Link
                key={c.id}
                to="/captures"
                className="ch-row clickable"
                style={{
                  display: "flex",
                  flexDirection: "column",
                  gap: 8,
                  textDecoration: "none",
                }}
              >
                <p
                  style={
                    {
                      fontSize: "var(--fs-sm)",
                      margin: 0,
                      color: "var(--text)",
                      lineHeight: 1.55,
                      display: "-webkit-box",
                      WebkitLineClamp: 2,
                      WebkitBoxOrient: "vertical",
                      overflow: "hidden",
                    } as React.CSSProperties
                  }
                >
                  {c.rawText ?? c.transcript ?? "—"}
                </p>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  {c.createdAt && (
                    <span className="ch-meta" style={{ marginLeft: "auto" }}>
                      {timeAgo(c.createdAt, i18n.language)}
                    </span>
                  )}
                </div>
              </Link>
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function Landing() {
  const { t } = useTranslation();
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        minHeight: "100vh",
        gap: 16,
      }}
    >
      <div
        style={{
          width: 48,
          height: 48,
          borderRadius: 12,
          background: "var(--accent)",
          color: "#fff",
          display: "grid",
          placeItems: "center",
          fontSize: 24,
          fontWeight: 800,
        }}
      >
        C
      </div>
      <h1 className="ch-title">{t("brand")}</h1>
      <p style={{ color: "var(--text-muted)", fontSize: "var(--fs-sm)" }}>
        {t("tagline")}
      </p>
      <div style={{ display: "flex", gap: 10, marginTop: 8 }}>
        <Link to="/login" className="ch-btn ch-btn-primary">
          {t("signIn")}
        </Link>
        <Link to="/register" className="ch-btn">
          {t("createAccount")}
        </Link>
      </div>
    </div>
  );
}

function Index() {
  const { data: me, isLoading } = useGetMe();
  if (isLoading) return null;
  if (!me) return <Landing />;
  return <Dashboard />;
}
