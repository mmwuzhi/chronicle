export function MutationToast({
  message,
}: {
  message: string | null;
}): React.JSX.Element | null {
  if (!message) return null;
  return (
    <div className="ch-mutation-toast" role="alert">
      {message}
    </div>
  );
}
