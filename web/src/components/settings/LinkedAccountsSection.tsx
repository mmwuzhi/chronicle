import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { useGetMe } from "../../api";
import { useConfirm } from "../../hooks/use-confirm";
import { apiFetch } from "../../lib/apiFetch";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { SettingsLabel, SettingsRow } from "../ui/settings-row";

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
      <h3 className="mb-0 mt-4 text-small font-bold text-ink">
        {t("account.linkedAccounts")}
      </h3>
      <div className="divide-y divide-hairline">
        {OAUTH_PROVIDERS.map((provider) => {
          const account = linked.find((a) => a.provider === provider);
          return (
            <SettingsRow key={provider}>
              <SettingsLabel>
                <b>{capitalize(provider)}</b>
              </SettingsLabel>
              {account ? (
                <div className="flex items-center gap-2.5">
                  <Badge className="bg-faint/15 text-faint">
                    {t("account.connected")}
                  </Badge>
                  <Button
                    size="sm"
                    onClick={() => handleDisconnect(account)}
                    disabled={unlinking === account.id}
                  >
                    {t("account.disconnect")}
                  </Button>
                </div>
              ) : (
                <Button size="sm" onClick={() => handleConnect(provider)}>
                  {t("account.connect")}
                </Button>
              )}
            </SettingsRow>
          );
        })}
      </div>
    </>
  );
}
