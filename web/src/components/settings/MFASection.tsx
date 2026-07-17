import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { useGetMe } from "@/api";
import { MFASetupModal } from "@/components/settings/MFASetupModal";
import { MFADisableModal } from "@/components/settings/MFADisableModal";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SettingsLabel, SettingsRow } from "@/components/ui/settings-row";

export function MFASection() {
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
    <SettingsRow>
      <SettingsLabel>
        <b>{t("security.mfa.title")}</b>
        <span>{t("security.mfa.description")}</span>
      </SettingsLabel>
      {totpEnabled ? (
        <div className="flex items-center gap-2.5">
          <Badge className="bg-faint/15 text-faint">
            {t("security.mfa.enabled")}
          </Badge>
          <Button size="sm" onClick={() => setDisableOpen(true)}>
            {t("security.mfa.disable")}
          </Button>
        </div>
      ) : (
        <Button size="sm" onClick={() => setSetupOpen(true)}>
          {t("security.mfa.enable")}
        </Button>
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
    </SettingsRow>
  );
}
