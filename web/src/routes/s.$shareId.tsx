import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useGetPublicCaptureShare } from "@/api";
import { Markdown } from "@/components/Markdown";
import { NotFoundPage } from "@/components/NotFoundPage";
import { Button } from "@/components/ui/button";
import { Meta } from "@/components/ui/page";
import { fmtPreciseDateTime } from "@/utils/format";

export const Route = createFileRoute("/s/$shareId")({
  component: SharedCapture,
});

function SharedCapture(): React.JSX.Element {
  const { shareId } = Route.useParams();
  const { t, i18n } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const [copied, setCopied] = useState(false);
  const [secret, setSecret] = useState(() => window.location.hash.slice(1));
  const query = useGetPublicCaptureShare(shareId, {
    request: { headers: { Authorization: `Share ${secret}` } },
    query: {
      enabled: secret.length > 0,
      queryKey: ["/public/shares", shareId, secret],
      retry: false,
    },
  });

  useEffect(() => {
    const updateSecret = () => {
      setSecret(window.location.hash.slice(1));
      setCopied(false);
    };
    window.addEventListener("hashchange", updateSecret);
    return () => window.removeEventListener("hashchange", updateSecret);
  }, []);

  useEffect(() => {
    const previousTitle = document.title;
    document.title = `${t("share.sharedTitle")} · Chronicle`;
    const robots = document.createElement("meta");
    robots.name = "robots";
    robots.content = "noindex, nofollow, noarchive";
    const referrer = document.createElement("meta");
    referrer.name = "referrer";
    referrer.content = "no-referrer";
    document.head.append(robots, referrer);
    return () => {
      document.title = previousTitle;
      robots.remove();
      referrer.remove();
    };
  }, [t]);

  if (!secret || query.error) return <NotFoundPage />;
  if (query.isLoading) {
    return (
      <main className="grid min-h-screen place-items-center">
        <Meta>{t("share.loading")}</Meta>
      </main>
    );
  }
  if (!query.data) return <NotFoundPage />;

  const copyText = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(query.data.snapshotRawText);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  return (
    <main className="min-h-screen px-4 py-6 md:py-10">
      <article className="mx-auto w-full max-w-[680px]">
        <header className="mb-8 flex items-center justify-between gap-4 border-b border-hairline pb-4">
          <Link
            to="/"
            className="flex items-center gap-2 font-app-display text-small font-bold text-ink no-underline"
          >
            <span className="grid size-7 place-items-center rounded-control bg-accent text-caption font-extrabold text-accent-text">
              C
            </span>
            Chronicle
          </Link>
          <Button size="sm" onClick={() => void copyText()}>
            {copied ? t("share.copied") : tc("actions.copy")}
          </Button>
        </header>

        <div className="mb-6 font-code text-caption text-faint">
          {fmtPreciseDateTime(query.data.capturedAt, i18n.language)}
        </div>

        <div className="ch-shared-capture text-body leading-[1.75]">
          <Markdown publicSafe>{query.data.snapshotRawText}</Markdown>
        </div>
      </article>
    </main>
  );
}
