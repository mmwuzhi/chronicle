export function fmtDateTime(iso: string): string {
  const d = new Date(iso);
  return (
    d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) +
    " " +
    d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
  );
}

export function fmtDate(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

// Shared list-timestamp rule, mirrored by the desktop app's CaptureTime:
// relative under 7 days, then the short date, adding the year once it differs.
export function fmtListTime(iso: string, locale: string): string {
  const d = new Date(iso);
  if (Date.now() - d.getTime() < 7 * 24 * 60 * 60 * 1000) {
    return timeAgo(iso, locale);
  }
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(locale, {
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  });
}

// Precise stamp for tooltips and detail contexts ("Jul 4, 2026 · 2:35pm"),
// the same shape as the desktop app's hover timestamp.
export function fmtPreciseDateTime(iso: string, locale?: string): string {
  const d = new Date(iso);
  const date = d.toLocaleDateString(locale, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
  const time = d
    .toLocaleTimeString(locale, {
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })
    .toLowerCase()
    .replace(/\s/g, "");
  return `${date} · ${time}`;
}

export function timeAgo(iso: string, locale: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (Math.abs(diff) < 60000) return relativeNow(locale, rtf);
  const m = Math.floor(diff / 60000);
  if (m < 60) return rtf.format(-m, "minute");
  const h = Math.floor(m / 60);
  if (h < 24) return rtf.format(-h, "hour");
  return rtf.format(-Math.floor(h / 24), "day");
}

function relativeNow(
  locale: string,
  formatter: Intl.RelativeTimeFormat,
): string {
  switch (locale.toLowerCase().split(/[-_]/)[0]) {
    case "en":
      return "now";
    case "ja":
      return "たった今";
    case "zh":
      return "刚刚";
    default:
      return formatter.format(0, "second");
  }
}

export function fmtFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const digits =
    value >= 10 || unitIndex === 0 || Number.isInteger(value) ? 0 : 1;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
}
