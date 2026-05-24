import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { z } from "zod/v3";
import { useTranslation } from "react-i18next";

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
      <div className="flex items-center justify-center min-h-screen">
        <div className="w-full max-w-sm p-8 bg-white rounded-xl border border-gray-200 shadow-sm text-center">
          <p className="text-sm text-red-500">{t("mfa.tokenExpired")}</p>
          <button
            onClick={() => navigate({ to: "/login" })}
            className="mt-4 text-sm text-gray-900 font-medium hover:underline"
          >
            {t("login.submit")}
          </button>
        </div>
      </div>
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
    <div className="flex items-center justify-center min-h-screen">
      <div className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm">
        <h1 className="text-xl font-semibold">{t("mfa.title")}</h1>
        <p className="text-sm text-gray-500">{t("mfa.enterCode")}</p>

        <input
          type="text"
          autoComplete="one-time-code"
          maxLength={8}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") handleVerify();
          }}
          placeholder={t("mfa.placeholder")}
          className="border border-gray-300 rounded-md px-3 py-2 text-sm text-center tracking-widest focus:outline-none focus:ring-2 focus:ring-gray-900"
          autoFocus
        />

        {error && <p className="text-red-500 text-sm">{error}</p>}

        <button
          onClick={handleVerify}
          disabled={verifying || !code.trim()}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {verifying ? t("mfa.verifying") : t("mfa.verify")}
        </button>
      </div>
    </div>
  );
}
