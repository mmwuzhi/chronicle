import { memo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { rehypeTodoChip } from "../utils/rehype-todo-chip";

// Memoized on the source string: react-markdown runs the full remark → rehype
// parse on every render, so without this a single-item cache patch re-parses
// every capture in the loaded feed.
export const Markdown = memo(function Markdown({
  children,
}: {
  children: string;
}) {
  if (!children) return null;
  return (
    <div className="ch-prose">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeTodoChip]}
      >
        {children}
      </ReactMarkdown>
    </div>
  );
});
