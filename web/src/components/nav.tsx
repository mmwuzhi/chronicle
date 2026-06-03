import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { SearchModal } from "./search-modal";

const HomeIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25"
    />
  </svg>
);
const CaptureIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M16.862 4.487l1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"
    />
  </svg>
);
const TaskIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
    />
  </svg>
);
const ProjectIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z"
    />
  </svg>
);
const ReportIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 0 1 3 19.875v-6.75ZM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 0 1-1.125-1.125V8.625ZM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 0 1-1.125-1.125V4.125Z"
    />
  </svg>
);
const SearchIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="8" />
    <path d="m21 21-4.35-4.35" />
  </svg>
);

const tabs = [
  { to: "/" as const, labelKey: "nav.home", icon: <HomeIcon />, exact: true },
  { to: "/captures" as const, labelKey: "nav.captures", icon: <CaptureIcon /> },
  { to: "/tasks" as const, labelKey: "nav.tasks", icon: <TaskIcon /> },
  { to: "/projects" as const, labelKey: "nav.projects", icon: <ProjectIcon /> },
  { to: "/reports" as const, labelKey: "nav.reports", icon: <ReportIcon /> },
];

export function Nav() {
  const { t } = useTranslation();
  const [searchOpen, setSearchOpen] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <>
      <nav className="ch-topbar">
        <Link to="/" className="ch-brand">
          <span className="glyph">C</span>
          <span className="hidden md:inline">Chronicle</span>
        </Link>

        {/* Desktop centered nav links */}
        <div className="ch-navlinks">
          {tabs.map((tab) => (
            <Link
              key={tab.to}
              to={tab.to}
              className="ch-navlink"
              activeOptions={tab.exact ? { exact: true } : undefined}
            >
              {t(tab.labelKey)}
            </Link>
          ))}
        </div>

        <div className="ch-topbar-right">
          {/* Desktop search trigger */}
          <button
            className="ch-searchtrigger"
            onClick={() => setSearchOpen(true)}
          >
            <SearchIcon />
            <span
              style={{ color: "var(--text-faint)", fontSize: "var(--fs-sm)" }}
            >
              {t("search.placeholder")}
            </span>
            <kbd>⌘K</kbd>
          </button>

          {/* Mobile search icon */}
          <button
            className="ch-iconbtn ch-search-mobile"
            onClick={() => setSearchOpen(true)}
            aria-label={t("search.placeholder")}
          >
            <SearchIcon />
          </button>

          {/* Settings */}
          <Link
            to="/settings"
            search={{}}
            className="ch-navlink ch-settings-link"
          >
            {t("nav.settings")}
          </Link>
        </div>
      </nav>

      {/* Mobile bottom tab bar */}
      <div className="ch-tabbar">
        {tabs.map((tab) => (
          <Link
            key={tab.to}
            to={tab.to}
            className="ch-tab"
            activeOptions={tab.exact ? { exact: true } : undefined}
          >
            <span className="ch-tab-ico">{tab.icon}</span>
            <span>{t(tab.labelKey)}</span>
          </Link>
        ))}
      </div>

      {searchOpen && <SearchModal onClose={() => setSearchOpen(false)} />}
    </>
  );
}
