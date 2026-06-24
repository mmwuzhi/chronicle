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
const SearchIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={2} viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="8" />
    <path d="m21 21-4.35-4.35" />
  </svg>
);
const AskIcon = () => (
  <svg fill="none" stroke="currentColor" strokeWidth={1.75} viewBox="0 0 24 24">
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M8.625 9.75a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0H8.25m4.125 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0H12m4.125 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm0 0h-.375m-13.5 3.01c0 1.6 1.123 2.994 2.707 3.227 1.087.16 2.185.283 3.293.369V21l4.184-4.183a1.14 1.14 0 0 1 .778-.332 48.294 48.294 0 0 0 5.83-.498c1.585-.233 2.708-1.626 2.708-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"
    />
  </svg>
);
const SettingsIcon = () => (
  <svg
    width="18"
    height="18"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.75}
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
);

// The Ask page depends on the RAG sidecar, which isn't part of the deployed
// (Fly) image yet — only the host-run local-first setup has it. Show the tab in
// dev, or when a deployment that runs the sidecar opts in via VITE_ASK_ENABLED,
// so production users never see a tab that only 503s.
const ASK_ENABLED =
  import.meta.env.DEV || import.meta.env.VITE_ASK_ENABLED === "true";

const tabs = [
  { to: "/" as const, labelKey: "nav.home", icon: <HomeIcon />, exact: true },
  { to: "/captures" as const, labelKey: "nav.captures", icon: <CaptureIcon /> },
  ...(ASK_ENABLED
    ? [{ to: "/ask" as const, labelKey: "nav.ask", icon: <AskIcon /> }]
    : []),
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

          {/* Settings: gear icon on mobile, text link on desktop */}
          <Link
            to="/settings"
            search={{}}
            className="ch-settings-icon"
            aria-label={t("nav.settings")}
          >
            <SettingsIcon />
          </Link>
          <Link
            to="/settings"
            search={{}}
            className="ch-navlink ch-settings-text"
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
