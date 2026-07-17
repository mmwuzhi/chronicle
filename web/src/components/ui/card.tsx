import { Slot } from "@radix-ui/react-slot";
import type { HTMLAttributes } from "react";
import { cn } from "@/lib/cn";

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  asChild?: boolean;
}

export function Card({
  asChild = false,
  className,
  ...props
}: CardProps): React.JSX.Element {
  const Component = asChild ? Slot : "div";
  return (
    <Component
      className={cn(
        "rounded-card border border-line bg-surface shadow-card",
        className,
      )}
      {...props}
    />
  );
}
