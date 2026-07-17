import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { navPillClassName } from "./ui/tab";

export type CaptureTab = "all" | "todo";

interface CaptureFilterBarProps {
  tabs: CaptureTab[];
  activeTab: CaptureTab;
  showScheduled: boolean;
  onTabChange: (tab: CaptureTab) => void;
  onToggleScheduled: () => void;
}

export function CaptureFilterBar({
  tabs,
  activeTab,
  showScheduled,
  onTabChange,
  onToggleScheduled,
}: CaptureFilterBarProps): React.JSX.Element {
  const { t } = useTranslation("captures");

  return (
    <div className="mb-4 flex flex-wrap gap-1.5">
      {tabs.map((tab) => (
        <button
          key={tab}
          className={navPillClassName({ active: activeTab === tab })}
          onClick={() => onTabChange(tab)}
        >
          {t(`tabs.${tab}`)}
        </button>
      ))}
      <button
        className={navPillClassName({ active: showScheduled })}
        onClick={onToggleScheduled}
        title={t("scheduledHint")}
      >
        {t("showScheduled")}
      </button>
      <Link to="/trash" className={navPillClassName()}>
        {t("trash.link")}
      </Link>
    </div>
  );
}
