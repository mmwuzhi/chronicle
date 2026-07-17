import { useState } from "react";
import { useChangePassword } from "../../api";
import { useTranslation } from "react-i18next";
import { Button } from "../ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "../ui/dialog";
import { FieldError, FieldGroup, FieldLabel, Input } from "../ui/field";

export function PasswordModal({
  open,
  onOpenChange,
  hasPassword,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  hasPassword: boolean;
}) {
  const { t } = useTranslation("settings");
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");

  const changePassword = useChangePassword({
    mutation: {
      onSuccess: () => {
        setCurrentPassword("");
        setNewPassword("");
        onOpenChange(false);
      },
    },
  });

  const handleSubmit = () => {
    if (!newPassword.trim() || newPassword.length < 8) return;
    changePassword.mutate({
      data: {
        ...(hasPassword ? { currentPassword } : {}),
        newPassword,
      },
    });
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) {
          setCurrentPassword("");
          setNewPassword("");
        }
        onOpenChange(v);
      }}
    >
      <DialogContent>
        <DialogTitle>
          {hasPassword
            ? t("password.changePassword")
            : t("password.setPassword")}
        </DialogTitle>

        <DialogDescription>
          {hasPassword ? t("password.placeholder") : t("password.oauthSetHint")}
        </DialogDescription>

        {hasPassword && (
          <FieldGroup>
            <FieldLabel>{t("password.currentPassword")}</FieldLabel>
            <Input
              type="password"
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
            />
          </FieldGroup>
        )}

        <FieldGroup>
          <FieldLabel>{t("password.newPassword")}</FieldLabel>
          <Input
            type="password"
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleSubmit();
            }}
            placeholder={t("password.placeholder")}
          />
        </FieldGroup>

        {changePassword.isError && (
          <FieldError className="text-small">
            {(changePassword.error as { detail?: string })?.detail ??
              t("password.error")}
          </FieldError>
        )}

        <div className="mt-2 flex justify-end gap-3">
          <DialogClose asChild>
            <Button>{t("password.cancel")}</Button>
          </DialogClose>
          <Button
            variant="strong"
            onClick={handleSubmit}
            disabled={changePassword.isPending || newPassword.length < 8}
          >
            {changePassword.isPending
              ? t("password.saving")
              : hasPassword
                ? t("password.changePassword")
                : t("password.setPassword")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
