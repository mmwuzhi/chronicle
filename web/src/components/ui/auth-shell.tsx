import type { HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export const authPanelClassName =
  "flex w-full max-w-sm flex-col gap-4 rounded-card border border-line bg-surface p-8 shadow-card";

export function AuthShell({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return (
    <main
      className={cn(
        "flex min-h-screen items-center justify-center bg-page px-4 py-8",
        className,
      )}
      {...props}
    />
  );
}

export function AuthPanel({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return <div className={cn(authPanelClassName, className)} {...props} />;
}
