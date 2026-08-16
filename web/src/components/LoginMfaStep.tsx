import { useState, type ReactElement } from "react";
import { useTranslation } from "react-i18next";
import { AuthPanel, AuthShell } from "@/components/ui/auth-shell";
import { Button } from "@/components/ui/button";
import { FieldError, Input } from "@/components/ui/field";
import { completeSignIn } from "@/lib/post-auth-redirect";
import { isExpiredMfaTokenError, verifyMfa } from "@/lib/pre-auth";

export function LoginMfaStep({
  mfaToken,
  onBack,
}: {
  mfaToken: string;
  onBack: () => void;
}): ReactElement {
  const { t } = useTranslation("auth");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [verifying, setVerifying] = useState(false);

  const verify = async () => {
    if (!code.trim()) return;
    setError("");
    setVerifying(true);
    try {
      completeSignIn(await verifyMfa(mfaToken, code));
    } catch (error) {
      setError(
        isExpiredMfaTokenError(error)
          ? t("mfa.tokenExpired")
          : t("mfa.invalidCode"),
      );
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
