import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useLogin } from "@/api";
import { useTranslation } from "react-i18next";
import { LoginMfaStep } from "@/components/LoginMfaStep";
import { LoginProviders } from "@/components/LoginProviders";
import { AuthShell, authPanelClassName } from "@/components/ui/auth-shell";
import { Button } from "@/components/ui/button";
import {
  FieldError,
  FieldGroup,
  FieldLabel,
  Input,
} from "@/components/ui/field";
import { completeSignIn } from "@/lib/post-auth-redirect";

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
          completeSignIn(res.accessToken);
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
    <AuthShell>
      <form
        onSubmit={handleSubmit((data) => login.mutate({ data }))}
        className={authPanelClassName}
      >
        <h1 className="font-app-display text-title font-semibold text-ink">
          {t("login.title")}
        </h1>

        <FieldGroup>
          <FieldLabel>{t("login.email")}</FieldLabel>
          <Input type="email" autoComplete="email" {...register("email")} />
          {errors.email && <FieldError>{errors.email.message}</FieldError>}
        </FieldGroup>

        <FieldGroup>
          <FieldLabel>{t("login.password")}</FieldLabel>
          <Input
            type="password"
            autoComplete="current-password"
            {...register("password")}
          />
          {errors.password && (
            <FieldError>{errors.password.message}</FieldError>
          )}
        </FieldGroup>

        <div className="flex justify-end">
          <Link
            to="/forgot-password"
            className="text-caption text-muted hover:text-ink hover:underline"
          >
            {t("login.forgotPassword")}
          </Link>
        </div>

        {login.error && (
          <FieldError className="text-small">
            {t("login.invalidCredentials")}
          </FieldError>
        )}

        <Button
          type="submit"
          disabled={login.isPending}
          variant="strong"
          className="w-full"
        >
          {login.isPending ? t("login.signingIn") : t("login.submit")}
        </Button>

        <LoginProviders />

        <p className="text-center text-small text-muted">
          {t("login.noAccount")}{" "}
          <Link to="/register" className="font-medium text-ink hover:underline">
            {t("login.signUp")}
          </Link>
        </p>
      </form>
    </AuthShell>
  );
}
