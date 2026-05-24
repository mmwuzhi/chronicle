import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { z } from "zod/v3";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/auth/callback")({
  validateSearch: z.object({ access_token: z.string().default("") }),
  component: OAuthCallback,
});

function OAuthCallback() {
  const { t } = useTranslation("auth");
  const { access_token } = Route.useSearch();
  const navigate = useNavigate();

  useEffect(() => {
    if (access_token) {
      localStorage.setItem("access_token", access_token);
      navigate({ to: "/captures" });
    }
  }, [access_token, navigate]);

  return (
    <div className="flex items-center justify-center min-h-screen">
      <p className="text-sm text-gray-500">{t("callback.signingIn")}</p>
    </div>
  );
}
