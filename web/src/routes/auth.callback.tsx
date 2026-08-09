import { createFileRoute } from "@tanstack/react-router";
import { useEffect } from "react";
import { z } from "zod/v3";
import { useTranslation } from "react-i18next";
import { AuthShell } from "@/components/ui/auth-shell";
import { completeSignIn } from "@/lib/post-auth-redirect";

export const Route = createFileRoute("/auth/callback")({
  validateSearch: z.object({ access_token: z.string().default("") }),
  component: OAuthCallback,
});

function OAuthCallback() {
  const { t } = useTranslation("auth");
  const { access_token } = Route.useSearch();
  useEffect(() => {
    if (access_token) {
      completeSignIn(access_token);
    }
  }, [access_token]);

  return (
    <AuthShell>
      <p className="text-small text-muted">{t("callback.signingIn")}</p>
    </AuthShell>
  );
}
