import { useState } from "react";
import { useTranslation } from "react-i18next";
import { apiFetch } from "@/lib/apiFetch";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { FieldError, Input } from "@/components/ui/field";

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
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) {
          setCode("");
          setError("");
        }
        onOpenChange(v);
      }}
    >
      <DialogContent>
        <DialogTitle>{t("security.mfa.disableConfirm")}</DialogTitle>
        <DialogDescription>
          {t("security.mfa.disableDescription")}
        </DialogDescription>

        <Input
          type="text"
          inputMode="numeric"
          maxLength={8}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") handleSubmit();
          }}
          placeholder={t("security.mfa.enterCode")}
          className="text-center tracking-widest"
          autoFocus
        />

        {error && <FieldError className="text-small">{error}</FieldError>}

        <div className="flex justify-end gap-3">
          <DialogClose asChild>
            <Button>{t("password.cancel")}</Button>
          </DialogClose>
          <Button
            variant="danger"
            onClick={handleSubmit}
            disabled={loading || !code.trim()}
          >
            {loading ? t("password.saving") : t("security.mfa.disable")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
