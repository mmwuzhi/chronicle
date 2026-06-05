import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useQueryClient } from "@tanstack/react-query";
import { useGetMe } from "../../api";
import { MFASetupModal } from "./MFASetupModal";
import { MFADisableModal } from "./MFADisableModal";

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
    <div className="ch-setrow">
      <div className="lbl">
        <b>{t("security.mfa.title")}</b>
        <span>{t("security.mfa.description")}</span>
      </div>
      {totpEnabled ? (
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <span className="ch-pill st-done">{t("security.mfa.enabled")}</span>
          <button
            onClick={() => setDisableOpen(true)}
            className="ch-btn ch-btn-sm"
          >
            {t("security.mfa.disable")}
          </button>
        </div>
      ) : (
        <button onClick={() => setSetupOpen(true)} className="ch-btn ch-btn-sm">
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
