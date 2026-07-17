import { useState } from "react";
import { useTranslation } from "react-i18next";
import { useGetMe } from "@/api";
import { setTodoEnabled, useTodoEnabled } from "@/hooks/use-todo-enabled";
import { apiFetch } from "@/lib/apiFetch";
import { PasswordModal } from "@/components/settings/PasswordModal";
import { LinkedAccountsSection } from "@/components/settings/LinkedAccountsSection";
import { Button } from "@/components/ui/button";
import { Meta } from "@/components/ui/page";
import { SettingsLabel, SettingsRow } from "@/components/ui/settings-row";

const LANGS = [
  { code: "en", label: "English" },
  { code: "zh", label: "中文" },
  { code: "ja", label: "日本語" },
] as const;

export function AccountSection() {
  const { t } = useTranslation("settings");
  const { t: tc } = useTranslation("common");
  const [pwModalOpen, setPwModalOpen] = useState(false);
  const [resendState, setResendState] = useState<
    "idle" | "loading" | "sent" | "error"
  >("idle");
  const { data: me, isLoading } = useGetMe();

  if (isLoading) return <Meta>{tc("loading")}</Meta>;
  if (!me) return null;

  return (
    <>
      {!me.emailVerified && (
        <div className="mb-2 flex items-center justify-between gap-3 rounded-control border border-amber-300 bg-amber-50 px-4 py-3 text-small text-amber-900">
          <span>{t("profile.verifyHint")}</span>
          <Button
            size="sm"
            className="shrink-0"
            disabled={resendState !== "idle"}
            onClick={async () => {
              setResendState("loading");
              try {
                const res = await apiFetch("/auth/resend-verification", {
                  method: "POST",
                });
                setResendState(res.status === 429 ? "error" : "sent");
              } catch {
                setResendState("error");
              }
              setTimeout(() => setResendState("idle"), 4000);
            }}
          >
            {resendState === "loading"
              ? t("profile.verifySending")
              : resendState === "sent"
                ? t("profile.verifySent")
                : resendState === "error"
                  ? t("profile.verifyFailed")
                  : t("profile.verifyResend")}
          </Button>
        </div>
      )}

      <div className="divide-y divide-hairline">
        <SettingsRow>
          <SettingsLabel>
            <span>{t("profile.email")}</span>
          </SettingsLabel>
          <span className="text-small text-ink">{me.email}</span>
        </SettingsRow>
        <SettingsRow>
          <SettingsLabel>
            <span>{t("password.label")}</span>
          </SettingsLabel>
          <Button size="sm" onClick={() => setPwModalOpen(true)}>
            {me.hasPassword
              ? t("password.changePassword")
              : t("password.setPassword")}
          </Button>
        </SettingsRow>
        <LanguageRow />
        <TodoFeatureRow />
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
    <SettingsRow>
      <SettingsLabel>
        <span>{t("language.title")}</span>
      </SettingsLabel>
      <select
        value={
          LANGS.find((l) => i18n.language.startsWith(l.code))?.code ?? "en"
        }
        onChange={(e) => i18n.changeLanguage(e.target.value)}
        className="w-auto rounded-control border border-line bg-surface px-2.5 py-1.5 font-app text-small text-ink outline-none focus:border-accent focus:shadow-focus"
      >
        {LANGS.map((lang) => (
          <option key={lang.code} value={lang.code}>
            {lang.label}
          </option>
        ))}
      </select>
    </SettingsRow>
  );
}

function TodoFeatureRow() {
  const { t } = useTranslation("settings");
  const enabled = useTodoEnabled();
  return (
    <SettingsRow>
      <SettingsLabel>
        <span>{t("todoFeature.title")}</span>
        <Meta>{t("todoFeature.hint")}</Meta>
      </SettingsLabel>
      <input
        type="checkbox"
        checked={enabled}
        onChange={(e) => setTodoEnabled(e.target.checked)}
        className="size-4 cursor-pointer accent-accent"
      />
    </SettingsRow>
  );
}
