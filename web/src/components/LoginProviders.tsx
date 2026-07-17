import { useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Button, buttonClassName } from "./ui/button";
import { FieldError } from "./ui/field";

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

// Everything below the password form's divider: OAuth links and passkey
// sign-in. The passkey ceremony uses plain fetch (pre-auth, not in the
// OpenAPI spec) and owns its own failure state.
export function LoginProviders() {
  const { t } = useTranslation("auth");
  const navigate = useNavigate();
  const [passkeyError, setPasskeyError] = useState(false);
  const apiBase = import.meta.env.VITE_API_URL ?? "/api";

  const handlePasskeyLogin = async () => {
    setPasskeyError(false);
    try {
      const { startAuthentication } = await import("@simplewebauthn/browser");

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
      navigate({ to: "/" });
    } catch {
      // user cancelled
    }
  };

  return (
    <>
      <div className="relative flex items-center gap-3">
        <div className="h-px flex-1 bg-line" />
        <span className="text-caption text-faint">{t("common:or")}</span>
        <div className="h-px flex-1 bg-line" />
      </div>

      <a
        href={`${apiBase}/auth/google`}
        className={buttonClassName({ className: "w-full" })}
      >
        <GoogleIcon />
        {t("login.continueGoogle")}
      </a>

      <a
        href={`${apiBase}/auth/github`}
        className={buttonClassName({ className: "w-full" })}
      >
        <GitHubIcon />
        {t("login.continueGithub")}
      </a>

      <Button type="button" onClick={handlePasskeyLogin} className="w-full">
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
      </Button>

      {passkeyError && (
        <FieldError className="text-small">
          {t("login.passkeyFailed")}
        </FieldError>
      )}
    </>
  );
}
