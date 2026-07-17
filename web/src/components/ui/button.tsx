import { Slot } from "@radix-ui/react-slot";
import type { ButtonHTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export type ButtonVariant =
  | "default"
  | "strong"
  | "primary"
  | "ghost"
  | "danger"
  | "ai";
export type ButtonSize = "sm" | "md" | "icon";

const variantClasses: Record<ButtonVariant, string> = {
  default:
    "border-strong bg-surface text-ink [@media(hover:hover)]:hover:bg-tint",
  strong:
    "border-ink bg-ink text-surface [@media(hover:hover)]:hover:border-muted [@media(hover:hover)]:hover:bg-muted",
  primary:
    "border-accent bg-accent text-accent-text [@media(hover:hover)]:hover:border-accent-strong [@media(hover:hover)]:hover:bg-accent-strong",
  ghost:
    "border-transparent bg-transparent text-muted shadow-none [@media(hover:hover)]:hover:bg-tint [@media(hover:hover)]:hover:text-ink",
  danger:
    "border-danger bg-danger text-surface [@media(hover:hover)]:hover:border-danger-strong [@media(hover:hover)]:hover:bg-danger-strong",
  ai: "border-accent-soft bg-accent-weak text-accent-strong [@media(hover:hover)]:hover:bg-accent-soft",
};

const sizeClasses: Record<ButtonSize, string> = {
  sm: "min-h-8 px-[11px] py-1.5 text-caption",
  md: "min-h-10 px-[15px] py-2 text-small",
  icon: "size-10 p-0",
};

export function buttonClassName({
  variant = "default",
  size = "md",
  className,
}: {
  variant?: ButtonVariant;
  size?: ButtonSize;
  className?: string;
} = {}): string {
  return cn(
    "inline-flex shrink-0 cursor-pointer touch-manipulation items-center justify-center gap-[7px] whitespace-nowrap rounded-control border font-app font-semibold leading-none shadow-card transition-[background-color,border-color,color,opacity,transform] duration-150 focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-accent/20 active:scale-[0.96] disabled:pointer-events-none disabled:opacity-45 [&_svg]:size-4",
    variantClasses[variant],
    sizeClasses[size],
    className,
  );
}

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  asChild?: boolean;
  variant?: ButtonVariant;
  size?: ButtonSize;
}

export function Button({
  asChild = false,
  variant = "default",
  size = "md",
  className,
  type,
  ...props
}: ButtonProps): React.JSX.Element {
  const Component = asChild ? Slot : "button";
  return (
    <Component
      className={buttonClassName({ variant, size, className })}
      type={asChild ? undefined : (type ?? "button")}
      {...props}
    />
  );
}
