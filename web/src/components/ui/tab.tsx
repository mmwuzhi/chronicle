import { cn } from "@/lib/cn";

export function navPillClassName({
  active = false,
  className,
}: {
  active?: boolean;
  className?: string;
} = {}): string {
  return cn(
    "inline-flex cursor-pointer items-center whitespace-nowrap rounded-full border-0 bg-transparent px-[13px] py-[7px] font-app text-small font-medium text-muted no-underline transition-colors hover:bg-tint hover:text-ink",
    active && "bg-accent-weak font-semibold text-accent-strong",
    className,
  );
}

export function sectionTabClassName(active: boolean): string {
  return cn(
    "-mb-px cursor-pointer border-0 border-b-2 border-transparent bg-transparent px-0 py-2.5 font-app text-body font-semibold text-faint transition-colors hover:text-muted",
    active && "border-accent text-ink",
  );
}
