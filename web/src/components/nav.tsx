import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";

export function Nav() {
  const { t } = useTranslation();

  return (
    <nav className="sticky top-0 z-50 border-b border-gray-200 bg-white">
      <div className="max-w-3xl mx-auto px-8 h-12 flex items-center gap-6">
        <span className="font-semibold text-sm tracking-tight text-gray-900">
          {t("brand")}
        </span>
        <div className="flex items-center gap-4 text-sm">
          <Link
            to="/captures"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            {t("nav.captures")}
          </Link>
          <Link
            to="/tasks"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            {t("nav.tasks")}
          </Link>
          <Link
            to="/projects"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            {t("nav.projects")}
          </Link>
        </div>
        <div className="ml-auto">
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
  );
}
