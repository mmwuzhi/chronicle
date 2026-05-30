import { useState } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { useTranslation } from "react-i18next";
import { apiFetch } from "../../lib/apiFetch";

export function MFADisableModal({
  open,
  onOpenChange,
  onDisabled,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onDisabled: () => void;
}) {
  const { t } = useTranslation("settings");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleSubmit = async () => {
    if (!code.trim()) return;
    setError("");
    setLoading(true);
    try {
      const res = await apiFetch("/auth/mfa/disable", {
        method: "POST",
        body: JSON.stringify({ code }),
      });
      if (!res.ok) {
        setError(t("security.mfa.invalidCode"));
        return;
      }
      onDisabled();
      setCode("");
      onOpenChange(false);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog.Root
      open={open}
      onOpenChange={(v) => {
        if (!v) {
          setCode("");
          setError("");
        }
        onOpenChange(v);
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black/40" />
        <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
          <Dialog.Title className="text-lg font-semibold">
            {t("security.mfa.disableConfirm")}
          </Dialog.Title>
          <p className="text-sm text-gray-500">
            {t("security.mfa.disableDescription")}
          </p>

          <input
            type="text"
            inputMode="numeric"
            maxLength={8}
            value={code}
            onChange={(e) => setCode(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleSubmit();
            }}
            placeholder={t("security.mfa.enterCode")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm text-center tracking-widest focus:outline-none focus:ring-2 focus:ring-gray-900"
            autoFocus
          />

          {error && <p className="text-red-500 text-sm">{error}</p>}

          <div className="flex justify-end gap-3">
            <Dialog.Close asChild>
              <button className="text-sm px-4 py-2 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors">
                {t("password.cancel")}
              </button>
            </Dialog.Close>
            <button
              onClick={handleSubmit}
              disabled={loading || !code.trim()}
              className="text-sm px-4 py-2 rounded-md bg-red-600 text-white hover:bg-red-700 transition-colors disabled:opacity-50"
            >
              {loading ? t("password.saving") : t("security.mfa.disable")}
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
