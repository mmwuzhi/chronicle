import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { rehypeTodoChip } from "../utils/rehype-todo-chip";

export function Markdown({ children }: { children: string }) {
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
}
