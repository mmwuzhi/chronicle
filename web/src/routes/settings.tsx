import { createFileRoute, useNavigate, useSearch } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { z } from "zod";
import { Nav } from "../components/nav";
import { useConfirm } from "../components/confirm-dialog";
import { useGetMe, useChangePassword, useDeleteAccount } from "../api";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";

export const Route = createFileRoute("/settings")({
  component: Settings,
  validateSearch: z.object({
    oauth_linked: z.string().optional(),
    oauth_error: z.string().optional(),
  }),
});

const LANGS = [
  { code: "en", label: "English" },
  { code: "zh", label: "中文" },
  { code: "ja", label: "日本語" },
] as const;

const OAUTH_PROVIDERS = ["google", "github"] as const;

type Section = "account" | "security" | "danger";

function PasswordModal({
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

function capitalize(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function LinkedAccountsSection() {
  const { t } = useTranslation("settings");
  const confirm = useConfirm();
  const queryClient = useQueryClient();
  const { data: me } = useGetMe();
  const [unlinking, setUnlinking] = useState<string | null>(null);

  if (!me) return null;

  const linked = (me as unknown as { oauthAccounts?: { id: string; provider: string }[] }).oauthAccounts ?? [];

  const handleConnect = (provider: string) => {
    const token = localStorage.getItem("access_token");
    const apiBase = import.meta.env.VITE_API_URL ?? "/api";
    window.location.assign(`${apiBase}/auth/${provider}?action=link&token=${token}`);
  };

  const handleDisconnect = async (account: { id: string; provider: string }) => {
    if (!me.hasPassword && linked.length <= 1) {
      await confirm({
        title: t("account.disconnect"),
        description: t("account.cannotDisconnect"),
        confirmLabel: "OK",
      });
      return;
    }

    const ok = await confirm({
      title: t("account.disconnectConfirm", { provider: capitalize(account.provider) }),
      description: t("account.disconnectDescription", { provider: capitalize(account.provider) }),
      confirmLabel: t("account.disconnect"),
      variant: "danger",
    });

    if (!ok) return;

    setUnlinking(account.id);
    try {
      const token = localStorage.getItem("access_token");
      const apiBase = import.meta.env.VITE_API_URL ?? "/api";
      await fetch(`${apiBase}/users/me/oauth-accounts/${account.id}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${token}` },
      });
      queryClient.invalidateQueries({ queryKey: ["/users/me"] });
    } finally {
      setUnlinking(null);
    }
  };

  return (
    <>
      <h3 className="text-sm font-medium text-gray-900 pt-4">
        {t("account.linkedAccounts")}
      </h3>
      <div className="divide-y divide-gray-100">
        {OAUTH_PROVIDERS.map((provider) => {
          const account = linked.find((a) => a.provider === provider);
          return (
            <div
              key={provider}
              className="flex items-center justify-between py-4"
            >
              <span className="text-sm text-gray-500">
                {capitalize(provider)}
              </span>
              {account ? (
                <div className="flex items-center gap-3">
                  <span className="text-xs text-green-600 bg-green-50 px-2 py-0.5 rounded-full">
                    {t("account.connected")}
                  </span>
                  <button
                    onClick={() => handleDisconnect(account)}
                    disabled={unlinking === account.id}
                    className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors disabled:opacity-50"
                  >
                    {t("account.disconnect")}
                  </button>
                </div>
              ) : (
                <button
                  onClick={() => handleConnect(provider)}
                  className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
                >
                  {t("account.connect")}
                </button>
              )}
            </div>
          );
        })}
      </div>
    </>
  );
}

function AccountSection() {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const [pwModalOpen, setPwModalOpen] = useState(false);
  const { data: me, isLoading } = useGetMe();

  if (isLoading) {
    return <div className="text-gray-400 text-sm">{tc("loading")}</div>;
  }

  if (!me) return null;

  const linked = (me as unknown as { oauthAccounts?: { id: string; provider: string }[] }).oauthAccounts ?? [];

  return (
    <>
      <h2 className="text-lg font-semibold">{t("account.title")}</h2>

      {!me.emailVerified && (
        <div className="rounded-md bg-amber-50 border border-amber-200 px-4 py-3 text-sm text-amber-700">
          {t("profile.verifyHint")}
        </div>
      )}

      <div className="divide-y divide-gray-100">
        <div className="flex items-center justify-between py-4">
          <span className="text-sm text-gray-500">{t("profile.email")}</span>
          <span className="text-sm">{me.email}</span>
        </div>
        <div className="flex items-center justify-between py-4">
          <span className="text-sm text-gray-500">
            {t("profile.authMethod")}
          </span>
          <span className="text-sm">
            {linked.length > 0
              ? linked.map((a) => capitalize(a.provider)).join(", ")
              : "Email"}
          </span>
        </div>
        <div className="flex items-center justify-between py-4">
          <span className="text-sm text-gray-500">{t("password.label")}</span>
          <button
            onClick={() => setPwModalOpen(true)}
            className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
          >
            {me.hasPassword
              ? t("password.changePassword")
              : t("password.setPassword")}
          </button>
        </div>
        <LanguageRow />
      </div>

      <LinkedAccountsSection />

      <PasswordModal
        open={pwModalOpen}
        onOpenChange={setPwModalOpen}
        hasPassword={me.hasPassword}
      />
    </>
  );
}

function LanguageRow() {
  const { t, i18n } = useTranslation("settings");

  return (
    <div className="flex items-center justify-between py-4">
      <span className="text-sm text-gray-500">{t("language.title")}</span>
      <select
        value={LANGS.find((l) => i18n.language.startsWith(l.code))?.code ?? "en"}
        onChange={(e) => i18n.changeLanguage(e.target.value)}
        className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
      >
        {LANGS.map((lang) => (
          <option key={lang.code} value={lang.code}>
            {lang.label}
          </option>
        ))}
      </select>
    </div>
  );
}

function apiFetch(path: string, options: RequestInit = {}) {
  const token = localStorage.getItem("access_token");
  const apiBase = import.meta.env.VITE_API_URL ?? "/api";
  return fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...options.headers,
    },
  });
}

function PasskeysSection() {
  const { t } = useTranslation("settings");
  const confirm = useConfirm();
  const [passkeys, setPasskeys] = useState<
    { id: string; name: string; createdAt: string }[]
  >([]);
  const [loading, setLoading] = useState(true);
  const [adding, setAdding] = useState(false);

  const fetchPasskeys = async () => {
    try {
      const res = await apiFetch("/auth/passkeys");
      if (res.ok) {
        const data = await res.json();
        setPasskeys(data.passkeys ?? []);
      }
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchPasskeys();
  }, []);

  const handleAdd = async () => {
    setAdding(true);
    try {
      const { startRegistration } = await import("@simplewebauthn/browser");

      const beginRes = await apiFetch("/auth/passkeys/register/begin", {
        method: "POST",
      });
      if (!beginRes.ok) return;
      const { options } = await beginRes.json();

      const credential = await startRegistration({ optionsJSON: options });

      const finishRes = await apiFetch("/auth/passkeys/register/finish", {
        method: "POST",
        body: JSON.stringify({ credential, name: "Passkey" }),
      });
      if (finishRes.ok) {
        fetchPasskeys();
      }
    } catch {
      // user cancelled or browser doesn't support
    } finally {
      setAdding(false);
    }
  };

  const handleDelete = async (pk: { id: string; name: string }) => {
    const ok = await confirm({
      title: t("security.passkeys.deleteConfirm"),
      description: t("security.passkeys.deleteDescription"),
      confirmLabel: t("security.passkeys.delete"),
      variant: "danger",
    });
    if (!ok) return;

    await apiFetch(`/auth/passkeys/${pk.id}`, { method: "DELETE" });
    fetchPasskeys();
  };

  return (
    <div>
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-medium">{t("security.passkeys.title")}</h3>
          <p className="text-sm text-gray-500 mt-0.5">
            {t("security.passkeys.description")}
          </p>
        </div>
        <button
          onClick={handleAdd}
          disabled={adding}
          className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors disabled:opacity-50 shrink-0 ml-4"
        >
          {t("security.passkeys.add")}
        </button>
      </div>

      {loading ? null : passkeys.length === 0 ? (
        <p className="text-sm text-gray-400 mt-3">
          {t("security.passkeys.empty")}
        </p>
      ) : (
        <div className="mt-3 divide-y divide-gray-100">
          {passkeys.map((pk) => (
            <div
              key={pk.id}
              className="flex items-center justify-between py-3"
            >
              <div>
                <p className="text-sm">{pk.name}</p>
                <p className="text-xs text-gray-400">
                  {new Date(pk.createdAt).toLocaleDateString()}
                </p>
              </div>
              <button
                onClick={() => handleDelete(pk)}
                className="text-sm text-gray-500 hover:text-red-600 transition-colors"
              >
                {t("security.passkeys.delete")}
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

type MFASetupStep = "idle" | "qr" | "recovery";

function MFASetupModal({
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

function QRCodeCanvas({ uri }: { uri: string }) {
  const [QR, setQR] = useState<typeof import("qrcode.react") | null>(null);

  useEffect(() => {
    import("qrcode.react").then(setQR);
  }, []);

  if (!QR) return null;
  return <QR.QRCodeSVG value={uri} size={200} />;
}

function MFADisableModal({
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

function MFASection() {
  const { t } = useTranslation("settings");
  const queryClient = useQueryClient();
  const { data: me } = useGetMe();
  const [setupOpen, setSetupOpen] = useState(false);
  const [disableOpen, setDisableOpen] = useState(false);

  const totpEnabled = me?.totpEnabled ?? false;

  const setTotpEnabled = (value: boolean) => {
    queryClient.setQueryData(
      ["/users/me"],
      (old: { totpEnabled?: boolean } | undefined) =>
        old ? { ...old, totpEnabled: value } : old,
    );
  };

  return (
    <div className="flex items-center justify-between">
      <div>
        <p className="text-sm font-medium">{t("security.mfa.title")}</p>
        <p className="text-sm text-gray-500 mt-0.5">
          {t("security.mfa.description")}
        </p>
      </div>
      {totpEnabled ? (
        <div className="flex items-center gap-3">
          <span className="text-xs text-green-600 bg-green-50 px-2 py-0.5 rounded-full">
            {t("security.mfa.enabled")}
          </span>
          <button
            onClick={() => setDisableOpen(true)}
            className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
          >
            {t("security.mfa.disable")}
          </button>
        </div>
      ) : (
        <button
          onClick={() => setSetupOpen(true)}
          className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
        >
          {t("security.mfa.enable")}
        </button>
      )}

      <MFASetupModal
        open={setupOpen}
        onOpenChange={setSetupOpen}
        onEnabled={() => setTotpEnabled(true)}
      />
      <MFADisableModal
        open={disableOpen}
        onOpenChange={setDisableOpen}
        onDisabled={() => setTotpEnabled(false)}
      />
    </div>
  );
}

function SecuritySection() {
  const { t } = useTranslation("settings");

  return (
    <>
      <h2 className="text-lg font-semibold">{t("security.title")}</h2>

      <div className="divide-y divide-gray-100">
        <div className="py-4">
          <PasskeysSection />
        </div>

        <div className="py-4">
          <MFASection />
        </div>
      </div>
    </>
  );
}

function DangerSection() {
  const { t } = useTranslation("settings");
  const navigate = useNavigate();
  const confirm = useConfirm();

  const deleteMutation = useDeleteAccount({
    mutation: {
      onSuccess: () => {
        localStorage.removeItem("access_token");
        navigate({ to: "/" });
      },
    },
  });

  const handleDelete = async () => {
    const ok = await confirm({
      title: t("danger.confirmTitle"),
      description: t("danger.confirmDescription"),
      confirmLabel: t("danger.confirmLabel"),
      variant: "danger",
    });
    if (ok) deleteMutation.mutate();
  };

  return (
    <>
      <h2 className="text-lg font-semibold">{t("danger.title")}</h2>

      <div className="divide-y divide-gray-100">
        <div className="flex items-center justify-between py-4">
          <div>
            <p className="text-sm">{t("danger.deleteDescription")}</p>
          </div>
          <button
            onClick={handleDelete}
            disabled={deleteMutation.isPending}
            className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors shrink-0 ml-8"
          >
            {deleteMutation.isPending
              ? t("danger.deleting")
              : t("danger.deleteAccount")}
          </button>
        </div>
        {deleteMutation.isError && (
          <p className="py-4 text-sm text-red-500">
            {t("danger.deleteFailed")}
          </p>
        )}
      </div>
    </>
  );
}

function Settings() {
  const { t } = useTranslation("settings");
  const navigate = useNavigate();
  const search = useSearch({ from: "/settings" });
  const queryClient = useQueryClient();
  const [section, setSection] = useState<Section>("account");
  const [toast, setToast] = useState<string | null>(() => {
    if (search.oauth_linked)
      return t("account.linkSuccess", {
        provider: capitalize(search.oauth_linked),
      });
    if (search.oauth_error) return t("account.linkError");
    return null;
  });

  const { error } = useGetMe();

  useEffect(() => {
    if (search.oauth_linked) {
      queryClient.invalidateQueries({ queryKey: ["/users/me"] });
      window.history.replaceState({}, "", "/settings");
    } else if (search.oauth_error) {
      window.history.replaceState({}, "", "/settings");
    }
  }, [search.oauth_linked, search.oauth_error, queryClient]);

  useEffect(() => {
    if (toast) {
      const timer = setTimeout(() => setToast(null), 4000);
      return () => clearTimeout(timer);
    }
  }, [toast]);

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
  }

  const tabs: { id: Section; label: string }[] = [
    { id: "account", label: t("account.title") },
    { id: "security", label: t("security.title") },
    { id: "danger", label: t("danger.title") },
  ];

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />

      {toast && (
        <div className="fixed top-16 left-1/2 -translate-x-1/2 z-50 bg-gray-900 text-white text-sm px-4 py-2 rounded-lg shadow-lg">
          {toast}
        </div>
      )}

      <div className="max-w-4xl mx-auto px-8 py-12 flex gap-12">
        <nav className="w-44 shrink-0 flex flex-col gap-1">
          <h1 className="text-xl font-semibold mb-4">{t("title")}</h1>
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setSection(tab.id)}
              className={`text-left text-sm px-3 py-2 rounded-md transition-colors ${
                section === tab.id
                  ? "bg-gray-200/70 font-medium text-gray-900"
                  : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>

        <div className="flex-1 flex flex-col gap-4 min-w-0">
          {section === "account" && <AccountSection />}
          {section === "security" && <SecuritySection />}
          {section === "danger" && <DangerSection />}
        </div>
      </div>
    </div>
  );
}
