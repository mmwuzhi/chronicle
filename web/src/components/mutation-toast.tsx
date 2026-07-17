export function MutationToast({
  message,
}: {
  message: string | null;
}): React.JSX.Element | null {
  if (!message) return null;
  return (
    <div
      className="fixed bottom-[22px] right-[18px] z-100 max-w-[min(360px,calc(100vw-36px))] rounded-control bg-danger-strong px-3.5 py-[11px] text-small text-surface shadow-overlay"
      role="alert"
    >
      {message}
    </div>
  );
}
