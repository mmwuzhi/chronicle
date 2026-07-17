import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";

import enCommon from "@/locales/en/common.json";
import enAuth from "@/locales/en/auth.json";
import enCaptures from "@/locales/en/captures.json";
import enSettings from "@/locales/en/settings.json";
import enDashboard from "@/locales/en/dashboard.json";

import jaCommon from "@/locales/ja/common.json";
import jaAuth from "@/locales/ja/auth.json";
import jaCaptures from "@/locales/ja/captures.json";
import jaSettings from "@/locales/ja/settings.json";
import jaDashboard from "@/locales/ja/dashboard.json";

import zhCommon from "@/locales/zh/common.json";
import zhAuth from "@/locales/zh/auth.json";
import zhCaptures from "@/locales/zh/captures.json";
import zhSettings from "@/locales/zh/settings.json";
import zhDashboard from "@/locales/zh/dashboard.json";

i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: {
        common: enCommon,
        auth: enAuth,
        captures: enCaptures,
        settings: enSettings,
        dashboard: enDashboard,
      },
      ja: {
        common: jaCommon,
        auth: jaAuth,
        captures: jaCaptures,
        settings: jaSettings,
        dashboard: jaDashboard,
      },
      zh: {
        common: zhCommon,
        auth: zhAuth,
        captures: zhCaptures,
        settings: zhSettings,
        dashboard: zhDashboard,
      },
    },
    fallbackLng: "en",
    defaultNS: "common",
    interpolation: { escapeValue: false },
    detection: {
      order: ["localStorage", "navigator"],
      caches: ["localStorage"],
      lookupLocalStorage: "language",
    },
  });

export default i18n;
