export function DueBadge({
  dueAt,
  t,
}: {
  dueAt: string;
  t: (k: string) => string;
}) {
  const todayStr = new Date().toLocaleDateString("en-CA");
  const dueStr = new Date(dueAt).toLocaleDateString("en-CA");
  const overdue = dueStr < todayStr;
  const isToday = dueStr === todayStr;
  const label = overdue
    ? t("overdue")
    : isToday
      ? t("dueToday")
      : new Date(dueAt).toLocaleDateString(undefined, {
          month: "short",
          day: "numeric",
        });
  const variant = overdue ? "due-over" : isToday ? "due-today" : "due-future";
  return <span className={`ch-due ${variant}`}>{label}</span>;
}
