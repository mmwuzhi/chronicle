import type { HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export function SettingsRow({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return (
    <div
      className={cn("flex items-center gap-3.5 py-4", className)}
      {...props}
    />
  );
}

export function SettingsLabel({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return (
    <div
      className={cn(
        "min-w-0 flex-1 [&_b]:block [&_b]:text-body [&_b]:font-semibold [&_b]:text-ink [&_span]:mt-0.5 [&_span]:block [&_span]:text-small [&_span]:text-muted",
        className,
      )}
      {...props}
    />
  );
}
