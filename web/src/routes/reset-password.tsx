import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useMutation } from "@tanstack/react-query";
import { api } from "../lib/axios";
import { useTranslation } from "react-i18next";
import {
  AuthPanel,
  AuthShell,
  authPanelClassName,
} from "../components/ui/auth-shell";
import { Button } from "../components/ui/button";
import {
  FieldError,
  FieldGroup,
  FieldLabel,
  Input,
} from "../components/ui/field";

export const Route = createFileRoute("/reset-password")({
  validateSearch: z.object({ token: z.string().default("") }),
  component: ResetPassword,
});

const resetPassword = (token: string, password: string) =>
  api<{ accessToken: string }>({
    url: "/auth/reset-password",
    method: "POST",
    data: { token, password },
  });

function ResetPassword() {
  const { t } = useTranslation("auth");
  const { token } = Route.useSearch();
  const navigate = useNavigate();
  const mutation = useMutation({
    mutationFn: (password: string) => resetPassword(token, password),
    onSuccess: (data) => {
      localStorage.setItem("access_token", data.accessToken);
      navigate({ to: "/" });
    },
  });

  const schema = z
    .object({
      password: z.string().min(8, t("register.passwordMinLength")),
      confirmPassword: z.string().min(1, t("register.confirmRequired")),
    })
    .refine((d) => d.password === d.confirmPassword, {
      message: t("register.passwordsNoMatch"),
      path: ["confirmPassword"],
    });
  type FormData = z.infer<typeof schema>;

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  if (!token) {
    return (
      <AuthShell>
        <AuthPanel className="text-center">
          <h1 className="font-app-display text-title font-semibold text-ink">
            {t("resetPassword.invalidLink")}
          </h1>
          <p className="text-small text-muted">
            {t("resetPassword.useResetLink")}
          </p>
          <Link
            to="/forgot-password"
            className="mt-2 text-small font-medium text-ink hover:underline"
          >
            {t("resetPassword.requestNewLink")}
          </Link>
        </AuthPanel>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <form
        onSubmit={handleSubmit((data) => mutation.mutate(data.password))}
        className={authPanelClassName}
      >
        <h1 className="font-app-display text-title font-semibold text-ink">
          {t("resetPassword.title")}
        </h1>

        <FieldGroup>
          <FieldLabel>{t("resetPassword.newPassword")}</FieldLabel>
          <Input
            type="password"
            autoComplete="new-password"
            {...register("password")}
          />
          {errors.password && (
            <FieldError>{errors.password.message}</FieldError>
          )}
        </FieldGroup>

        <FieldGroup>
          <FieldLabel>{t("resetPassword.confirmNewPassword")}</FieldLabel>
          <Input
            type="password"
            autoComplete="new-password"
            {...register("confirmPassword")}
          />
          {errors.confirmPassword && (
            <FieldError>{errors.confirmPassword.message}</FieldError>
          )}
        </FieldGroup>

        {mutation.isError && (
          <FieldError className="text-small">
            {t("resetPassword.linkExpired")}
          </FieldError>
        )}

        <Button
          type="submit"
          disabled={mutation.isPending}
          variant="strong"
          className="w-full"
        >
          {mutation.isPending
            ? t("resetPassword.saving")
            : t("resetPassword.submit")}
        </Button>
      </form>
    </AuthShell>
  );
}
