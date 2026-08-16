import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod/v3";
import { useTranslation } from "react-i18next";
import { LoginMfaStep } from "@/components/LoginMfaStep";
import { AuthPanel, AuthShell } from "@/components/ui/auth-shell";
import { Button } from "@/components/ui/button";
import { FieldError } from "@/components/ui/field";

export const Route = createFileRoute("/auth/mfa")({
  validateSearch: z.object({ mfa_token: z.string().default("") }),
  component: MFAVerify,
});

function MFAVerify() {
  const { t } = useTranslation("auth");
  const { mfa_token } = Route.useSearch();
  const navigate = useNavigate();

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

  return (
    <LoginMfaStep
      mfaToken={mfa_token}
      onBack={() => navigate({ to: "/login" })}
    />
  );
}
