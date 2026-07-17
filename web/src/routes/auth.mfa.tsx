import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { z } from "zod/v3";
import { useTranslation } from "react-i18next";
import { AuthPanel, AuthShell } from "../components/ui/auth-shell";
import { Button } from "../components/ui/button";
import { FieldError, Input } from "../components/ui/field";

export const Route = createFileRoute("/auth/mfa")({
  validateSearch: z.object({ mfa_token: z.string().default("") }),
  component: MFAVerify,
});

function MFAVerify() {
  const { t } = useTranslation("auth");
  const { mfa_token } = Route.useSearch();
  const navigate = useNavigate();
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [verifying, setVerifying] = useState(false);

  if (!mfa_token) {
    return (
      <AuthShell>
        <AuthPanel className="text-center">
          <FieldError className="text-small">
            {t("mfa.tokenExpired")}
          </FieldError>
          <Button
            variant="ghost"
            onClick={() => navigate({ to: "/login" })}
            className="mt-4"
          >
            {t("login.submit")}
          </Button>
        </AuthPanel>
      </AuthShell>
    );
  }

  const handleVerify = async () => {
    if (!code.trim()) return;
    setError("");
    setVerifying(true);
    try {
      const apiBase = import.meta.env.VITE_API_URL ?? "/api";
      const res = await fetch(`${apiBase}/auth/mfa/verify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mfaToken: mfa_token, code }),
        credentials: "include",
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        if (res.status === 401) {
          setError(
            (data as { detail?: string }).detail?.includes("expired")
              ? t("mfa.tokenExpired")
              : t("mfa.invalidCode"),
          );
        } else {
          setError(t("mfa.invalidCode"));
        }
        return;
      }
      const { accessToken } = await res.json();
      localStorage.setItem("access_token", accessToken);
      navigate({ to: "/captures" });
    } finally {
      setVerifying(false);
    }
  };

  return (
    <AuthShell>
      <AuthPanel>
        <h1 className="font-app-display text-title font-semibold text-ink">
          {t("mfa.title")}
        </h1>
        <p className="text-small text-muted">{t("mfa.enterCode")}</p>

        <Input
          type="text"
          autoComplete="one-time-code"
          maxLength={8}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") handleVerify();
          }}
          placeholder={t("mfa.placeholder")}
          className="text-center tracking-widest"
          autoFocus
        />

        {error && <FieldError className="text-small">{error}</FieldError>}

        <Button
          variant="strong"
          className="w-full"
          onClick={handleVerify}
          disabled={verifying || !code.trim()}
        >
          {verifying ? t("mfa.verifying") : t("mfa.verify")}
        </Button>
      </AuthPanel>
    </AuthShell>
  );
}
