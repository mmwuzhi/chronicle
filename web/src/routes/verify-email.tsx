import { createFileRoute, Link } from "@tanstack/react-router";
import { useMutation } from "@tanstack/react-query";
import { useEffect } from "react";
import { z } from "zod/v3";
import { api } from "../lib/axios";
import { useTranslation } from "react-i18next";

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
    <div className="flex items-center justify-center min-h-screen">
      <div className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm text-center">
        {mutation.isPending && (
          <p className="text-sm text-gray-500">{t("verifyEmail.verifying")}</p>
        )}
        {mutation.isSuccess && (
          <>
            <h1 className="text-xl font-semibold">
              {t("verifyEmail.verified")}
            </h1>
            <p className="text-sm text-gray-600">
              {t("verifyEmail.verifiedDescription")}
            </p>
            <Link
              to="/login"
              className="mt-2 text-sm text-gray-900 font-medium hover:underline"
            >
              {t("login.submit")}
            </Link>
          </>
        )}
        {mutation.isError && (
          <>
            <h1 className="text-xl font-semibold">
              {t("verifyEmail.linkInvalid")}
            </h1>
            <p className="text-sm text-gray-600">
              {t("verifyEmail.linkExpiredOrUsed")}
            </p>
            <Link
              to="/login"
              className="mt-2 text-sm text-gray-900 font-medium hover:underline"
            >
              {t("verifyEmail.backToSignIn")}
            </Link>
          </>
        )}
        {!token && (
          <>
            <h1 className="text-xl font-semibold">
              {t("verifyEmail.missingToken")}
            </h1>
            <p className="text-sm text-gray-600">
              {t("verifyEmail.useVerificationLink")}
            </p>
          </>
        )}
      </div>
    </div>
  );
}
