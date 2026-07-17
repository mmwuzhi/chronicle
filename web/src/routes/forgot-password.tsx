import { createFileRoute } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useState } from "react";
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

export const Route = createFileRoute("/forgot-password")({
  component: ForgotPassword,
});

const schema = z.object({ email: z.string().email() });
type FormData = z.infer<typeof schema>;

const forgotPassword = (email: string) =>
  api<void>({
    url: "/auth/forgot-password",
    method: "POST",
    data: { email },
  });

function ForgotPassword() {
  const { t } = useTranslation("auth");
  const [submitted, setSubmitted] = useState(false);
  const mutation = useMutation({
    mutationFn: (email: string) => forgotPassword(email),
    onSuccess: () => setSubmitted(true),
    onError: () => setSubmitted(true),
  });

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  if (submitted) {
    return (
      <AuthShell>
        <AuthPanel className="text-center">
          <h1 className="font-app-display text-title font-semibold text-ink">
            {t("forgotPassword.checkInbox")}
          </h1>
          <p className="text-small text-muted">
            {t("forgotPassword.sentDescription")}
          </p>
        </AuthPanel>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <form
        onSubmit={handleSubmit((data) => mutation.mutate(data.email))}
        className={authPanelClassName}
      >
        <h1 className="font-app-display text-title font-semibold text-ink">
          {t("forgotPassword.title")}
        </h1>
        <p className="text-small text-muted">
          {t("forgotPassword.description")}
        </p>

        <FieldGroup>
          <FieldLabel>{t("forgotPassword.email")}</FieldLabel>
          <Input type="email" autoComplete="email" {...register("email")} />
          {errors.email && <FieldError>{errors.email.message}</FieldError>}
        </FieldGroup>

        <Button
          type="submit"
          disabled={mutation.isPending}
          variant="strong"
          className="w-full"
        >
          {mutation.isPending
            ? t("forgotPassword.sending")
            : t("forgotPassword.submit")}
        </Button>
      </form>
    </AuthShell>
  );
}
