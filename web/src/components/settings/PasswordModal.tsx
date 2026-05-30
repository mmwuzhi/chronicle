import { useState } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { useChangePassword } from "../../api";
import { useTranslation } from "react-i18next";

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
    <Dialog.Root
      open={open}
      onOpenChange={(v) => {
        if (!v) {
          setCurrentPassword("");
          setNewPassword("");
        }
        onOpenChange(v);
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black/40" />
        <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
          <Dialog.Title className="text-lg font-semibold">
            {hasPassword
              ? t("password.changePassword")
              : t("password.setPassword")}
          </Dialog.Title>

          {!hasPassword && (
            <p className="text-sm text-gray-500">
              {t("password.oauthSetHint")}
            </p>
          )}

          {hasPassword && (
            <div className="flex flex-col gap-1">
              <label className="text-sm text-gray-500">
                {t("password.currentPassword")}
              </label>
              <input
                type="password"
                value={currentPassword}
                onChange={(e) => setCurrentPassword(e.target.value)}
                className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
              />
            </div>
          )}

          <div className="flex flex-col gap-1">
            <label className="text-sm text-gray-500">
              {t("password.newPassword")}
            </label>
            <input
              type="password"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleSubmit();
              }}
              placeholder={t("password.placeholder")}
              className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
            />
          </div>

          {changePassword.isError && (
            <p className="text-sm text-red-500">
              {(changePassword.error as { detail?: string })?.detail ??
                t("password.error")}
            </p>
          )}

          <div className="flex justify-end gap-3 mt-2">
            <Dialog.Close asChild>
              <button className="text-sm px-4 py-2 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors">
                {t("password.cancel")}
              </button>
            </Dialog.Close>
            <button
              onClick={handleSubmit}
              disabled={changePassword.isPending || newPassword.length < 8}
              className="text-sm px-4 py-2 rounded-md bg-gray-900 text-white hover:bg-gray-700 transition-colors disabled:opacity-50"
            >
              {changePassword.isPending
                ? t("password.saving")
                : hasPassword
                  ? t("password.changePassword")
                  : t("password.setPassword")}
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
