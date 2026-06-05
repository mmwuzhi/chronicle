import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { useGetMe } from "../../api";
import { useConfirm } from "../confirm-dialog";
import { apiFetch } from "../../lib/apiFetch";

const OAUTH_PROVIDERS = ["google", "github"] as const;

function capitalize(s: string) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export function LinkedAccountsSection() {
  const { t } = useTranslation("settings");
  const confirm = useConfirm();
  const queryClient = useQueryClient();
  const { data: me } = useGetMe();
  const [unlinking, setUnlinking] = useState<string | null>(null);

  if (!me) return null;

  const linked =
    (me as unknown as { oauthAccounts?: { id: string; provider: string }[] })
      .oauthAccounts ?? [];

  const handleConnect = (provider: string) => {
    const token = localStorage.getItem("access_token");
    const apiBase = import.meta.env.VITE_API_URL ?? "/api";
    window.location.assign(
      `${apiBase}/auth/${provider}?action=link&token=${token}`,
    );
  };

  const handleDisconnect = async (account: {
    id: string;
    provider: string;
  }) => {
    if (!me.hasPassword && linked.length <= 1) {
      await confirm({
        title: t("account.disconnect"),
        description: t("account.cannotDisconnect"),
        confirmLabel: "OK",
      });
      return;
    }

    const ok = await confirm({
      title: t("account.disconnectConfirm", {
        provider: capitalize(account.provider),
      }),
      description: t("account.disconnectDescription", {
        provider: capitalize(account.provider),
      }),
      confirmLabel: t("account.disconnect"),
      variant: "danger",
    });

    if (!ok) return;

    setUnlinking(account.id);
    try {
      await apiFetch(`/users/me/oauth-accounts/${account.id}`, {
        method: "DELETE",
      });
      queryClient.invalidateQueries({ queryKey: ["/users/me"] });
    } finally {
      setUnlinking(null);
    }
  };

  return (
    <>
      <h3
        style={{
          margin: "16px 0 0",
          fontSize: "var(--fs-sm)",
          fontWeight: 700,
          color: "var(--text)",
        }}
      >
        {t("account.linkedAccounts")}
      </h3>
      <div className="ch-divide">
        {OAUTH_PROVIDERS.map((provider) => {
          const account = linked.find((a) => a.provider === provider);
          return (
            <div key={provider} className="ch-setrow">
              <div className="lbl">
                <b>{capitalize(provider)}</b>
              </div>
              {account ? (
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <span className="ch-pill st-done">
                    {t("account.connected")}
                  </span>
                  <button
                    onClick={() => handleDisconnect(account)}
                    disabled={unlinking === account.id}
                    className="ch-btn ch-btn-sm"
                  >
                    {t("account.disconnect")}
                  </button>
                </div>
              ) : (
                <button
                  onClick={() => handleConnect(provider)}
                  className="ch-btn ch-btn-sm"
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
