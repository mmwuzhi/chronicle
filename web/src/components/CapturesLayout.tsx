import type { ReactNode } from "react";
import { PageShell } from "@/components/ui/page";

interface CapturesLayoutProps {
  header: ReactNode;
  composer: ReactNode;
  content: ReactNode;
}

export function CapturesLayout({
  header,
  composer,
  content,
}: CapturesLayoutProps): React.JSX.Element {
  return (
    <PageShell className="max-w-[1120px]">
      {header}
      <section>{composer}</section>
      <section>{content}</section>
    </PageShell>
  );
}
