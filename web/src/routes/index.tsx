import { createFileRoute, Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/")({
  component: Index,
});

function Index() {
  const { t } = useTranslation();

  return (
    <div className="flex flex-col items-center justify-center min-h-screen gap-4">
      <h1 className="text-4xl font-semibold tracking-tight">{t("brand")}</h1>
      <p className="text-gray-500">{t("tagline")}</p>
      <div className="flex gap-3 mt-4">
        <Link
          to="/login"
          className="px-4 py-2 rounded-md bg-gray-900 text-white text-sm hover:bg-gray-700 transition-colors"
        >
          {t("signIn")}
        </Link>
        <Link
          to="/register"
          className="px-4 py-2 rounded-md border border-gray-300 text-sm hover:bg-gray-100 transition-colors"
        >
          {t("createAccount")}
        </Link>
      </div>
    </div>
  );
}
