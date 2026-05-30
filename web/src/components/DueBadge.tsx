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
  const cls = overdue
    ? "bg-red-100 text-red-700"
    : isToday
      ? "bg-amber-100 text-amber-700"
      : "bg-gray-100 text-gray-500";
  return (
    <span className={`text-xs px-2 py-0.5 rounded-full flex-shrink-0 ${cls}`}>
      {label}
    </span>
  );
}
