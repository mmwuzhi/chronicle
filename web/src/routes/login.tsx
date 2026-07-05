import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useLogin } from "../api";
import { useTranslation } from "react-i18next";
import { LoginMfaStep } from "../components/LoginMfaStep";
import { LoginProviders } from "../components/LoginProviders";

export const Route = createFileRoute("/login")({
  component: Login,
});

const schema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});
type FormData = z.infer<typeof schema>;

function Login() {
  const { t } = useTranslation("auth");
  const navigate = useNavigate();
  const [mfaToken, setMfaToken] = useState<string | null>(null);

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
          navigate({ to: "/" });
        }
      },
    },
  });

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({
    resolver: zodResolver(schema),
  });

  if (mfaToken) {
    return (
      <LoginMfaStep mfaToken={mfaToken} onBack={() => setMfaToken(null)} />
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

        <LoginProviders />

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
