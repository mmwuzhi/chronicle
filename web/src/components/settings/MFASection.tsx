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
