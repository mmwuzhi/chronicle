import { useState, useEffect } from "react";
import { useTranslation } from "react-i18next";
import { useConfirm } from "@/hooks/use-confirm";
import { apiFetch } from "@/lib/apiFetch";
import { Button } from "@/components/ui/button";
import { Meta } from "@/components/ui/page";
import { SettingsLabel, SettingsRow } from "@/components/ui/settings-row";

export function PasskeysSection() {
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
      <SettingsRow>
        <SettingsLabel>
          <b>{t("security.passkeys.title")}</b>
          <span>{t("security.passkeys.description")}</span>
        </SettingsLabel>
        <Button size="sm" onClick={handleAdd} disabled={adding}>
          {t("security.passkeys.add")}
        </Button>
      </SettingsRow>

      {loading ? null : passkeys.length === 0 ? (
        <Meta className="mb-3 block">{t("security.passkeys.empty")}</Meta>
      ) : (
        <div className="divide-y divide-hairline">
          {passkeys.map((pk) => (
            <SettingsRow key={pk.id}>
              <SettingsLabel>
                <b>{pk.name}</b>
                <span>{new Date(pk.createdAt).toLocaleDateString()}</span>
              </SettingsLabel>
              <Button
                variant="ghost"
                size="sm"
                className="text-danger hover:bg-danger-weak hover:text-danger-strong"
                onClick={() => handleDelete(pk)}
              >
                {t("security.passkeys.delete")}
              </Button>
            </SettingsRow>
          ))}
        </div>
      )}
    </div>
  );
}
