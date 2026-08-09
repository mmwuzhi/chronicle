import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { buttonClassName } from "@/components/ui/button";
import { PageTitle } from "@/components/ui/page";

export function NotFoundPage(): React.JSX.Element {
  const { t } = useTranslation("common");
  return (
    <main className="grid min-h-screen place-items-center px-4">
      <div className="flex max-w-sm flex-col items-start gap-4">
        <span className="font-code text-caption font-semibold text-faint">
          404
        </span>
        <PageTitle>{t("notFound.title")}</PageTitle>
        <Link to="/" className={buttonClassName()}>
          {t("notFound.returnHome")}
        </Link>
      </div>
    </main>
  );
}
