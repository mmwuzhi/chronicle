import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { SearchModal } from "./search-modal";

export function Nav() {
  const { t } = useTranslation();
  const [searchOpen, setSearchOpen] = useState(false);

  return (
    <>
      <nav className="sticky top-0 z-50 border-b border-gray-200 bg-white">
        <div className="max-w-3xl mx-auto px-8 h-12 flex items-center gap-6">
          <Link to="/" className="font-semibold text-sm tracking-tight text-gray-900 hover:text-gray-700 transition-colors">
            {t("brand")}
          </Link>
          <div className="flex items-center gap-4 text-sm">
            <Link
              to="/captures"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">{t("nav.captures")}</span>
              <span className="absolute inset-0 flex items-center">{t("nav.captures")}</span>
            </Link>
            <Link
              to="/tasks"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">{t("nav.tasks")}</span>
              <span className="absolute inset-0 flex items-center">{t("nav.tasks")}</span>
            </Link>
            <Link
              to="/projects"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">{t("nav.projects")}</span>
              <span className="absolute inset-0 flex items-center">{t("nav.projects")}</span>
            </Link>
            <Link
              to="/reports"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">{t("nav.reports")}</span>
              <span className="absolute inset-0 flex items-center">{t("nav.reports")}</span>
            </Link>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <button
              onClick={() => setSearchOpen(true)}
              className="text-gray-400 hover:text-gray-700 transition-colors"
              aria-label="Search"
            >
              <svg className="w-4 h-4" fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
                <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
              </svg>
            </button>
            <Link
              to="/settings"
              search={{}}
              className="text-gray-400 hover:text-gray-900 transition-colors [&.active]:text-gray-900 text-sm"
            >
              {t("nav.settings")}
            </Link>
          </div>
        </div>
      </nav>
      {searchOpen && <SearchModal onClose={() => setSearchOpen(false)} />}
    </>
  );
}
