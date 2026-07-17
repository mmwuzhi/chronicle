import type { HTMLAttributes } from "react";
import { cn } from "../../lib/cn";

export function PageShell({
  className,
  ...props
}: HTMLAttributes<HTMLElement>): React.JSX.Element {
  return (
    <main
      className={cn("mx-auto w-full max-w-3xl px-[18px] pb-10", className)}
      {...props}
    />
  );
}

export function PageHeader({
  className,
  ...props
}: HTMLAttributes<HTMLElement>): React.JSX.Element {
  return (
    <header
      className={cn(
        "flex flex-col gap-1 py-[22px] md:pb-[18px] md:pt-[30px]",
        className,
      )}
      {...props}
    />
  );
}

export function PageTitle({
  className,
  ...props
}: HTMLAttributes<HTMLHeadingElement>): React.JSX.Element {
  return (
    <h1
      className={cn(
        "m-0 font-app-display text-title font-bold leading-[1.1] tracking-[-0.02em] text-ink",
        className,
      )}
      {...props}
    />
  );
}

export function PageSubtitle({
  className,
  ...props
}: HTMLAttributes<HTMLParagraphElement>): React.JSX.Element {
  return (
    <p className={cn("mt-1 text-small text-muted", className)} {...props} />
  );
}

export function Meta({
  className,
  ...props
}: HTMLAttributes<HTMLElement>): React.JSX.Element {
  return (
    <span
      className={cn("font-code text-caption text-faint", className)}
      {...props}
    />
  );
}

export function PageError({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return <div className={cn("p-8 text-danger", className)} {...props} />;
}

export function EmptyState({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>): React.JSX.Element {
  return (
    <div
      className={cn(
        "flex flex-col items-center gap-3 px-6 py-10 text-center text-faint [&_.ico]:grid [&_.ico]:size-[52px] [&_.ico]:place-items-center [&_.ico]:rounded-card [&_.ico]:bg-tint [&_.ico_svg]:size-[25px] [&_h4]:m-0 [&_h4]:font-app-display [&_h4]:text-[15px] [&_h4]:font-semibold [&_h4]:text-muted [&_p]:m-0 [&_p]:max-w-60 [&_p]:text-small [&_p]:leading-normal",
        className,
      )}
      {...props}
    />
  );
}
