import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { SearchModal } from "./search-modal";

export function Nav() {
  const { t } = useTranslation();
  const [searchOpen, setSearchOpen] = useState(false);

  const bottomTabs = [
    {
      to: "/" as const,
      label: t("nav.home"),
      icon: (
        <svg
          className="w-5 h-5"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25"
          />
        </svg>
      ),
    },
    {
      to: "/captures" as const,
      label: t("nav.captures"),
      icon: (
        <svg
          className="w-5 h-5"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M16.862 4.487l1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"
          />
        </svg>
      ),
    },
    {
      to: "/tasks" as const,
      label: t("nav.tasks"),
      icon: (
        <svg
          className="w-5 h-5"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
          />
        </svg>
      ),
    },
    {
      to: "/projects" as const,
      label: t("nav.projects"),
      icon: (
        <svg
          className="w-5 h-5"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z"
          />
        </svg>
      ),
    },
    {
      to: "/reports" as const,
      label: t("nav.reports"),
      icon: (
        <svg
          className="w-5 h-5"
          fill="none"
          stroke="currentColor"
          strokeWidth={1.5}
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 0 1 3 19.875v-6.75ZM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 0 1-1.125-1.125V8.625ZM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 0 1-1.125-1.125V4.125Z"
          />
        </svg>
      ),
    },
  ];

  return (
    <>
      <nav className="sticky top-0 z-50 border-b border-gray-200 bg-white">
        <div className="max-w-3xl mx-auto px-4 md:px-8 h-12 flex items-center gap-6">
          <Link
            to="/"
            className="font-semibold text-sm tracking-tight text-gray-900 hover:text-gray-700 transition-colors"
          >
            {t("brand")}
          </Link>
          <div className="hidden md:flex items-center gap-4 text-sm">
            <Link
              to="/captures"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">
                {t("nav.captures")}
              </span>
              <span className="absolute inset-0 flex items-center">
                {t("nav.captures")}
              </span>
            </Link>
            <Link
              to="/tasks"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">
                {t("nav.tasks")}
              </span>
              <span className="absolute inset-0 flex items-center">
                {t("nav.tasks")}
              </span>
            </Link>
            <Link
              to="/projects"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">
                {t("nav.projects")}
              </span>
              <span className="absolute inset-0 flex items-center">
                {t("nav.projects")}
              </span>
            </Link>
            <Link
              to="/reports"
              className="relative text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
            >
              <span className="font-medium invisible" aria-hidden="true">
                {t("nav.reports")}
              </span>
              <span className="absolute inset-0 flex items-center">
                {t("nav.reports")}
              </span>
            </Link>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <button
              onClick={() => setSearchOpen(true)}
              className="p-2 -m-2 text-gray-400 hover:text-gray-700 transition-colors"
              aria-label="Search"
            >
              <svg
                className="w-5 h-5"
                fill="none"
                stroke="currentColor"
                strokeWidth={2}
                viewBox="0 0 24 24"
              >
                <circle cx="11" cy="11" r="8" />
                <path d="m21 21-4.35-4.35" />
              </svg>
            </button>
            <Link
              to="/settings"
              search={{}}
              className="p-2 -m-2 text-gray-400 hover:text-gray-900 transition-colors [&.active]:text-gray-900 text-sm"
            >
              <span className="hidden md:inline">{t("nav.settings")}</span>
              <svg
                className="md:hidden w-5 h-5"
                fill="none"
                stroke="currentColor"
                strokeWidth={1.5}
                viewBox="0 0 24 24"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
                />
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                />
              </svg>
            </Link>
          </div>
        </div>
      </nav>

      {/* Bottom tab bar — mobile only */}
      <div className="fixed bottom-0 left-0 right-0 z-50 border-t border-gray-200 bg-white md:hidden">
        <div className="flex">
          {bottomTabs.map((tab) => (
            <Link
              key={tab.to}
              to={tab.to}
              className="flex-1 flex flex-col items-center py-2 gap-0.5 text-[10px] text-gray-400 [&.active]:text-gray-900 transition-colors"
            >
              {tab.icon}
              <span>{tab.label}</span>
            </Link>
          ))}
        </div>
      </div>

      {searchOpen && <SearchModal onClose={() => setSearchOpen(false)} />}
    </>
  );
}
