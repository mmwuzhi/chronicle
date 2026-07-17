import { useState, useEffect } from "react";
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

type MFASetupStep = "idle" | "qr" | "recovery";

function QRCodeCanvas({ uri }: { uri: string }) {
  const [QR, setQR] = useState<typeof import("qrcode.react") | null>(null);

  useEffect(() => {
    import("qrcode.react").then(setQR);
  }, []);

  if (!QR) return null;
  return <QR.QRCodeSVG value={uri} size={200} />;
}

export function MFASetupModal({
  open,
  onOpenChange,
  onEnabled,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onEnabled: () => void;
}) {
  const { t } = useTranslation("settings");
  const [step, setStep] = useState<MFASetupStep>("idle");
  const [secret, setSecret] = useState("");
  const [uri, setUri] = useState("");
  const [code, setCode] = useState("");
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!open || step !== "idle") return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError("");
      try {
        const res = await apiFetch("/auth/mfa/setup", { method: "POST" });
        if (!res.ok || cancelled) return;
        const data = await res.json();
        if (cancelled) return;
        setSecret(data.secret);
        setUri(data.uri);
        setStep("qr");
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, step]);

  const handleVerify = async () => {
    if (!code.trim()) return;
    setError("");
    setLoading(true);
    try {
      const res = await apiFetch("/auth/mfa/enable", {
        method: "POST",
        body: JSON.stringify({ code }),
      });
      if (!res.ok) {
        setError(t("security.mfa.enterCode"));
        return;
      }
      const data = await res.json();
      setRecoveryCodes(data.recoveryCodes);
      setStep("recovery");
      onEnabled();
    } finally {
      setLoading(false);
    }
  };

  const handleClose = () => {
    setStep("idle");
    setSecret("");
    setUri("");
    setCode("");
    setRecoveryCodes([]);
    setError("");
    onOpenChange(false);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) handleClose();
        else onOpenChange(true);
      }}
    >
      <DialogContent>
        <DialogTitle>
          {step === "recovery"
            ? t("security.mfa.recoveryCodes")
            : t("security.mfa.setupTitle")}
        </DialogTitle>
        <DialogDescription className={step === "idle" ? "sr-only" : undefined}>
          {step === "recovery"
            ? t("security.mfa.recoveryCodesDescription")
            : t("security.mfa.scanQR")}
        </DialogDescription>

        {step === "qr" && (
          <>
            <div className="flex justify-center py-2">
              <QRCodeCanvas uri={uri} />
            </div>
            <div>
              <p className="mb-1 text-caption text-muted">
                {t("security.mfa.manualEntry")}
              </p>
              <code className="block select-all break-all rounded-control bg-tint px-3 py-2 font-code text-caption text-ink">
                {secret}
              </code>
            </div>
            <Input
              type="text"
              inputMode="numeric"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleVerify();
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
                variant="strong"
                onClick={handleVerify}
                disabled={loading || code.length < 6}
              >
                {loading
                  ? t("password.saving")
                  : t("security.mfa.verifyAndEnable")}
              </Button>
            </div>
          </>
        )}

        {step === "recovery" && (
          <>
            <div className="grid grid-cols-2 gap-2 rounded-control bg-tint p-4">
              {recoveryCodes.map((c) => (
                <code key={c} className="text-center font-code text-small">
                  {c}
                </code>
              ))}
            </div>
            <Button variant="strong" onClick={handleClose} className="w-full">
              {t("security.mfa.recoveryCodesSaved")}
            </Button>
          </>
        )}

        {step === "idle" && (
          <div className="flex justify-center py-8">
            <div className="size-5 animate-spin rounded-full border-2 border-line border-t-ink" />
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
