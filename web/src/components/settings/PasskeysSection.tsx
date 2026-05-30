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
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-medium">
            {t("security.passkeys.title")}
          </h3>
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
            <div key={pk.id} className="flex items-center justify-between py-3">
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
