import { useState, useEffect } from "react";
import { useTranslation } from "react-i18next";
import { useConfirm } from "../confirm-dialog";
import { apiFetch } from "../../lib/apiFetch";

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
      <div className="ch-setrow">
        <div className="lbl">
          <b>{t("security.passkeys.title")}</b>
          <span>{t("security.passkeys.description")}</span>
        </div>
        <button
          onClick={handleAdd}
          disabled={adding}
          className="ch-btn ch-btn-sm"
        >
          {t("security.passkeys.add")}
        </button>
      </div>

      {loading ? null : passkeys.length === 0 ? (
        <p className="ch-meta" style={{ margin: "0 0 12px" }}>
          {t("security.passkeys.empty")}
        </p>
      ) : (
        <div className="ch-divide">
          {passkeys.map((pk) => (
            <div key={pk.id} className="ch-setrow">
              <div className="lbl">
                <b>{pk.name}</b>
                <span>{new Date(pk.createdAt).toLocaleDateString()}</span>
              </div>
              <button
                onClick={() => handleDelete(pk)}
                className="ch-btn ch-btn-danger ch-btn-sm"
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
