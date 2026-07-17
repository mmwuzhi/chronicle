import { createFileRoute, Link } from "@tanstack/react-router";
import { useMutation } from "@tanstack/react-query";
import { useEffect } from "react";
import { z } from "zod/v3";
import { api } from "@/lib/axios";
import { useTranslation } from "react-i18next";
import { AuthPanel, AuthShell } from "@/components/ui/auth-shell";

export const Route = createFileRoute("/verify-email")({
  validateSearch: z.object({ token: z.string().default("") }),
  component: VerifyEmail,
});

const verifyEmail = (token: string) =>
  api<void>({ url: "/auth/verify-email", method: "POST", data: { token } });

function VerifyEmail() {
  const { t } = useTranslation("auth");
  const { token } = Route.useSearch();
  const mutation = useMutation({ mutationFn: () => verifyEmail(token) });

  useEffect(() => {
    if (token) mutation.mutate();
  }, [token]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <AuthShell>
      <AuthPanel className="text-center">
        {mutation.isPending && (
          <p className="text-small text-muted">{t("verifyEmail.verifying")}</p>
        )}
        {mutation.isSuccess && (
          <>
            <h1 className="font-app-display text-title font-semibold text-ink">
              {t("verifyEmail.verified")}
            </h1>
            <p className="text-small text-muted">
              {t("verifyEmail.verifiedDescription")}
            </p>
            <Link
              to="/login"
              className="mt-2 text-small font-medium text-ink hover:underline"
            >
              {t("login.submit")}
            </Link>
          </>
        )}
        {mutation.isError && (
          <>
            <h1 className="font-app-display text-title font-semibold text-ink">
              {t("verifyEmail.linkInvalid")}
            </h1>
            <p className="text-small text-muted">
              {t("verifyEmail.linkExpiredOrUsed")}
            </p>
            <Link
              to="/login"
              className="mt-2 text-small font-medium text-ink hover:underline"
            >
              {t("verifyEmail.backToSignIn")}
            </Link>
          </>
        )}
        {!token && (
          <>
            <h1 className="font-app-display text-title font-semibold text-ink">
              {t("verifyEmail.missingToken")}
            </h1>
            <p className="text-small text-muted">
              {t("verifyEmail.useVerificationLink")}
            </p>
          </>
        )}
      </AuthPanel>
    </AuthShell>
  );
}
