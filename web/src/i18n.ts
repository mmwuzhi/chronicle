import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";

import enCommon from "./locales/en/common.json";
import enAuth from "./locales/en/auth.json";
import enTasks from "./locales/en/tasks.json";
import enProjects from "./locales/en/projects.json";
import enCaptures from "./locales/en/captures.json";
import enSettings from "./locales/en/settings.json";
import enReports from "./locales/en/reports.json";

import jaCommon from "./locales/ja/common.json";
import jaAuth from "./locales/ja/auth.json";
import jaTasks from "./locales/ja/tasks.json";
import jaProjects from "./locales/ja/projects.json";
import jaCaptures from "./locales/ja/captures.json";
import jaSettings from "./locales/ja/settings.json";
import jaReports from "./locales/ja/reports.json";

import zhCommon from "./locales/zh/common.json";
import zhAuth from "./locales/zh/auth.json";
import zhTasks from "./locales/zh/tasks.json";
import zhProjects from "./locales/zh/projects.json";
import zhCaptures from "./locales/zh/captures.json";
import zhSettings from "./locales/zh/settings.json";
import zhReports from "./locales/zh/reports.json";

i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: {
        common: enCommon,
        auth: enAuth,
        tasks: enTasks,
        projects: enProjects,
        captures: enCaptures,
        settings: enSettings,
        reports: enReports,
      },
      ja: {
        common: jaCommon,
        auth: jaAuth,
        tasks: jaTasks,
        projects: jaProjects,
        captures: jaCaptures,
        settings: jaSettings,
        reports: jaReports,
      },
      zh: {
        common: zhCommon,
        auth: zhAuth,
        tasks: zhTasks,
        projects: zhProjects,
        captures: zhCaptures,
        settings: zhSettings,
        reports: zhReports,
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
