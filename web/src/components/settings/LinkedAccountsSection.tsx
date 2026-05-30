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
