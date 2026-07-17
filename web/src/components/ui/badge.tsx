import type { HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export function Badge({
  className,
  ...props
}: HTMLAttributes<HTMLSpanElement>): React.JSX.Element {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border border-transparent px-2.5 py-1 font-code text-[11px] font-semibold leading-none tracking-[0.01em]",
        className,
      )}
      {...props}
    />
  );
}

export function TodoChip({
  done = false,
  className,
  ...props
}: HTMLAttributes<HTMLSpanElement> & { done?: boolean }): React.JSX.Element {
  return (
    <span
      className={cn(
        "inline-block whitespace-nowrap rounded-full px-1.5 text-[0.85em] font-semibold",
        done ? "bg-tint text-faint" : "bg-accent-weak/55 text-accent-strong",
        className,
      )}
      {...props}
    />
  );
}
