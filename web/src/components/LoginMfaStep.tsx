import { useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";

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
            if (e.key === "Enter") verify();
          }}
          placeholder={t("mfa.placeholder")}
          className="border border-gray-300 rounded-md px-3 py-2 text-sm text-center tracking-widest focus:outline-none focus:ring-2 focus:ring-gray-900"
          autoFocus
        />

        {error && <p className="text-red-500 text-sm">{error}</p>}

        <button
          onClick={verify}
          disabled={verifying || !code.trim()}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {verifying ? t("mfa.verifying") : t("mfa.verify")}
        </button>

        <button
          type="button"
          onClick={onBack}
          className="text-sm text-gray-500 hover:text-gray-900"
        >
          {t("verifyEmail.backToSignIn")}
        </button>
      </div>
    </div>
  );
}
