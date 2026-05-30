import { useState, useEffect } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { useTranslation } from "react-i18next";
import { apiFetch } from "../../lib/apiFetch";

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
    <Dialog.Root
      open={open}
      onOpenChange={(v) => {
        if (!v) handleClose();
        else onOpenChange(true);
      }}
    >
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black/40" />
        <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
          <Dialog.Title className="text-lg font-semibold">
            {step === "recovery"
              ? t("security.mfa.recoveryCodes")
              : t("security.mfa.setupTitle")}
          </Dialog.Title>

          {step === "qr" && (
            <>
              <p className="text-sm text-gray-500">
                {t("security.mfa.scanQR")}
              </p>
              <div className="flex justify-center py-2">
                <QRCodeCanvas uri={uri} />
              </div>
              <div>
                <p className="text-xs text-gray-500 mb-1">
                  {t("security.mfa.manualEntry")}
                </p>
                <code className="block text-xs bg-gray-100 rounded px-3 py-2 break-all select-all">
                  {secret}
                </code>
              </div>
              <input
                type="text"
                inputMode="numeric"
                maxLength={6}
                value={code}
                onChange={(e) => setCode(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") handleVerify();
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
                  onClick={handleVerify}
                  disabled={loading || code.length < 6}
                  className="text-sm px-4 py-2 rounded-md bg-gray-900 text-white hover:bg-gray-700 transition-colors disabled:opacity-50"
                >
                  {loading
                    ? t("password.saving")
                    : t("security.mfa.verifyAndEnable")}
                </button>
              </div>
            </>
          )}

          {step === "recovery" && (
            <>
              <p className="text-sm text-gray-500">
                {t("security.mfa.recoveryCodesDescription")}
              </p>
              <div className="grid grid-cols-2 gap-2 bg-gray-50 rounded-lg p-4">
                {recoveryCodes.map((c) => (
                  <code key={c} className="text-sm font-mono text-center">
                    {c}
                  </code>
                ))}
              </div>
              <button
                onClick={handleClose}
                className="text-sm px-4 py-2 rounded-md bg-gray-900 text-white hover:bg-gray-700 transition-colors"
              >
                {t("security.mfa.recoveryCodesSaved")}
              </button>
            </>
          )}

          {step === "idle" && (
            <div className="flex justify-center py-8">
              <div className="animate-spin h-5 w-5 border-2 border-gray-300 border-t-gray-900 rounded-full" />
            </div>
          )}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
