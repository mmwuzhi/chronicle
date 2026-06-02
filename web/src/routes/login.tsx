import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useLogin } from "../api";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/login")({
  component: Login,
});

const schema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});
type FormData = z.infer<typeof schema>;

function GoogleIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
      <path
        d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
        fill="#4285F4"
      />
      <path
        d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
        fill="#34A853"
      />
      <path
        d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z"
        fill="#FBBC05"
      />
      <path
        d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
        fill="#EA4335"
      />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="currentColor"
    >
      <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
    </svg>
  );
}

function Login() {
  const { t } = useTranslation("auth");
  const navigate = useNavigate();
  const [passkeyError, setPasskeyError] = useState(false);
  const [mfaToken, setMfaToken] = useState<string | null>(null);
  const [mfaCode, setMfaCode] = useState("");
  const [mfaError, setMfaError] = useState("");
  const [mfaVerifying, setMfaVerifying] = useState(false);

  const login = useLogin({
    mutation: {
      onSuccess: (data) => {
        const res = data as unknown as {
          accessToken?: string;
          mfaRequired?: boolean;
          mfaToken?: string;
        };
        if (res.mfaRequired && res.mfaToken) {
          setMfaToken(res.mfaToken);
          return;
        }
        if (res.accessToken) {
          localStorage.setItem("access_token", res.accessToken);
          navigate({ to: "/projects" });
        }
      },
    },
  });

  const handleMfaVerify = async () => {
    if (!mfaCode.trim() || !mfaToken) return;
    setMfaError("");
    setMfaVerifying(true);
    try {
      const apiBase = import.meta.env.VITE_API_URL ?? "/api";
      const res = await fetch(`${apiBase}/auth/mfa/verify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mfaToken, code: mfaCode }),
        credentials: "include",
      });
      if (!res.ok) {
        setMfaError(t("mfa.invalidCode"));
        return;
      }
      const { accessToken } = await res.json();
      localStorage.setItem("access_token", accessToken);
      navigate({ to: "/projects" });
    } finally {
      setMfaVerifying(false);
    }
  };

  const handlePasskeyLogin = async () => {
    setPasskeyError(false);
    try {
      const { startAuthentication } = await import("@simplewebauthn/browser");
      const apiBase = import.meta.env.VITE_API_URL ?? "/api";

      const beginRes = await fetch(`${apiBase}/auth/passkeys/login/begin`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      });
      if (!beginRes.ok) return;
      const { options } = await beginRes.json();

      const credential = await startAuthentication({ optionsJSON: options });

      const finishRes = await fetch(`${apiBase}/auth/passkeys/login/finish`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ credential }),
        credentials: "include",
      });
      if (!finishRes.ok) {
        setPasskeyError(true);
        return;
      }
      const { accessToken } = await finishRes.json();
      localStorage.setItem("access_token", accessToken);
      navigate({ to: "/projects" });
    } catch {
      // user cancelled
    }
  };

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({
    resolver: zodResolver(schema),
  });

  if (mfaToken) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm">
          <h1 className="text-xl font-semibold">{t("mfa.title")}</h1>
          <p className="text-sm text-gray-500">{t("mfa.enterCode")}</p>

          <input
            type="text"
            autoComplete="one-time-code"
            maxLength={8}
            value={mfaCode}
            onChange={(e) => setMfaCode(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleMfaVerify();
            }}
            placeholder={t("mfa.placeholder")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm text-center tracking-widest focus:outline-none focus:ring-2 focus:ring-gray-900"
            autoFocus
          />

          {mfaError && <p className="text-red-500 text-sm">{mfaError}</p>}

          <button
            onClick={handleMfaVerify}
            disabled={mfaVerifying || !mfaCode.trim()}
            className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            {mfaVerifying ? t("mfa.verifying") : t("mfa.verify")}
          </button>

          <button
            type="button"
            onClick={() => {
              setMfaToken(null);
              setMfaCode("");
              setMfaError("");
            }}
            className="text-sm text-gray-500 hover:text-gray-900"
          >
            {t("verifyEmail.backToSignIn")}
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex items-center justify-center min-h-screen">
      <form
        onSubmit={handleSubmit((data) => login.mutate({ data }))}
        className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm"
      >
        <h1 className="text-xl font-semibold">{t("login.title")}</h1>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">{t("login.email")}</label>
          <input
            type="email"
            autoComplete="email"
            {...register("email")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.email && (
            <p className="text-red-500 text-xs">{errors.email.message}</p>
          )}
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">{t("login.password")}</label>
          <input
            type="password"
            autoComplete="current-password"
            {...register("password")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.password && (
            <p className="text-red-500 text-xs">{errors.password.message}</p>
          )}
        </div>

        <div className="flex justify-end">
          <Link
            to="/forgot-password"
            className="text-xs text-gray-500 hover:text-gray-900 hover:underline"
          >
            {t("login.forgotPassword")}
          </Link>
        </div>

        {login.error && (
          <p className="text-red-500 text-sm">
            {t("login.invalidCredentials")}
          </p>
        )}

        <button
          type="submit"
          disabled={login.isPending}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {login.isPending ? t("login.signingIn") : t("login.submit")}
        </button>

        <div className="relative flex items-center gap-3">
          <div className="flex-1 h-px bg-gray-200" />
          <span className="text-xs text-gray-400">{t("common:or")}</span>
          <div className="flex-1 h-px bg-gray-200" />
        </div>

        <a
          href={`${import.meta.env.VITE_API_URL ?? "/api"}/auth/google`}
          className="flex items-center justify-center gap-2 border border-gray-300 rounded-md py-2 text-sm font-medium hover:bg-gray-50 transition-colors"
        >
          <GoogleIcon />
          {t("login.continueGoogle")}
        </a>

        <a
          href={`${import.meta.env.VITE_API_URL ?? "/api"}/auth/github`}
          className="flex items-center justify-center gap-2 border border-gray-300 rounded-md py-2 text-sm font-medium hover:bg-gray-50 transition-colors"
        >
          <GitHubIcon />
          {t("login.continueGithub")}
        </a>

        <button
          type="button"
          onClick={handlePasskeyLogin}
          className="flex items-center justify-center gap-2 border border-gray-300 rounded-md py-2 text-sm font-medium hover:bg-gray-50 transition-colors"
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d="M2 18v3c0 .6.4 1 1 1h4v-3h3v-3h2l1.4-1.4a6.5 6.5 0 1 0-4-4Z" />
            <circle cx="16.5" cy="7.5" r=".5" fill="currentColor" />
          </svg>
          {t("login.passkey")}
        </button>

        {passkeyError && (
          <p className="text-red-500 text-sm">{t("login.passkeyFailed")}</p>
        )}

        <p className="text-center text-sm text-gray-500">
          {t("login.noAccount")}{" "}
          <Link
            to="/register"
            className="text-gray-900 font-medium hover:underline"
          >
            {t("login.signUp")}
          </Link>
        </p>
      </form>
    </div>
  );
}
