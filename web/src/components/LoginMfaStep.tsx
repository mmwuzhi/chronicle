import { useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { AuthPanel, AuthShell } from "@/components/ui/auth-shell";
import { Button } from "@/components/ui/button";
import { FieldError, Input } from "@/components/ui/field";

// Second step of password sign-in when the account has TOTP enabled: exchanges
// the short-lived mfaToken plus the user's code for a real session. Plain fetch,
// not an orval hook — this runs pre-auth, like the passkey ceremonies.
export function LoginMfaStep({
  mfaToken,
  onBack,
}: {
  mfaToken: string;
  onBack: () => void;
}) {
  const { t } = useTranslation("auth");
  const navigate = useNavigate();
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [verifying, setVerifying] = useState(false);

  const verify = async () => {
    if (!code.trim()) return;
    setError("");
    setVerifying(true);
    try {
      const apiBase = import.meta.env.VITE_API_URL ?? "/api";
      const res = await fetch(`${apiBase}/auth/mfa/verify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mfaToken, code }),
        credentials: "include",
      });
      if (!res.ok) {
        setError(t("mfa.invalidCode"));
        return;
      }
      const { accessToken } = await res.json();
      localStorage.setItem("access_token", accessToken);
      navigate({ to: "/" });
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
            if (e.key === "Enter") verify();
          }}
          placeholder={t("mfa.placeholder")}
          className="text-center tracking-widest"
          autoFocus
        />

        {error && <FieldError className="text-small">{error}</FieldError>}

        <Button
          variant="strong"
          className="w-full"
          onClick={verify}
          disabled={verifying || !code.trim()}
        >
          {verifying ? t("mfa.verifying") : t("mfa.verify")}
        </Button>

        <Button variant="ghost" type="button" onClick={onBack}>
          {t("verifyEmail.backToSignIn")}
        </Button>
      </AuthPanel>
    </AuthShell>
  );
}
