import { memo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { rehypeTodoChip } from "@/utils/rehype-todo-chip";

// Memoized on the source string: react-markdown runs the full remark → rehype
// parse on every render, so without this a single-item cache patch re-parses
// every capture in the loaded feed.
export const Markdown = memo(function Markdown({
  children,
  publicSafe = false,
}: {
  children: string;
  publicSafe?: boolean;
}) {
  if (!children) return null;
  return (
    <div className="ch-prose">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeTodoChip]}
        components={
          publicSafe
            ? {
                img: () => null,
                a: ({ children: linkChildren, ...props }) => (
                  <a {...props} target="_blank" rel="noreferrer noopener">
                    {linkChildren}
                  </a>
                ),
              }
            : undefined
        }
      >
        {children}
      </ReactMarkdown>
    </div>
  );
});
