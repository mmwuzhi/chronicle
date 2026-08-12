import { memo, useEffect, useState } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { useTranslation } from "react-i18next";
import { rehypeTodoChip } from "@/utils/rehype-todo-chip";
import {
  localISODate,
  rehypeMarkdownTaskControls,
  updateMarkdownTask,
  type MarkdownTask,
} from "@/utils/markdown-task";

// Memoized on the source string: react-markdown runs the full remark → rehype
// parse on every render, so without this a single-item cache patch re-parses
// every capture in the loaded feed.
export const Markdown = memo(function Markdown({
  children,
  publicSafe = false,
  onTaskChange,
}: {
  children: string;
  publicSafe?: boolean;
  onTaskChange?: (markdown: string) => Promise<unknown>;
}): React.JSX.Element | null {
  const { t } = useTranslation("captures");
  const [draft, setDraft] = useState(children);
  const [savingTask, setSavingTask] = useState(false);
  const interactive = Boolean(onTaskChange) && !publicSafe;

  useEffect(() => {
    if (!savingTask) setDraft(children);
  }, [children, savingTask]);

  if (!children) return null;

  const commitTask = async (lineIndex: number, task: MarkdownTask) => {
    if (!onTaskChange || savingTask) return;
    const previous = draft;
    const next = updateMarkdownTask(previous, lineIndex, task);
    if (next === previous) return;

    setDraft(next);
    setSavingTask(true);
    try {
      await onTaskChange(next);
    } catch {
      setDraft(previous);
    } finally {
      setSavingTask(false);
    }
  };

  const components: Components = {};
  if (publicSafe) {
    components.img = () => null;
    components.a = ({ children: linkChildren, ...props }) => (
      <a {...props} target="_blank" rel="noreferrer noopener">
        {linkChildren}
      </a>
    );
  }
  if (interactive) {
    components.input = ({ node, type, checked, ...props }) => {
      if (type !== "checkbox") return <input type={type} {...props} />;
      const lineIndex = node?.properties.dataTaskLine;
      if (typeof lineIndex !== "number") {
        return <input type="checkbox" disabled {...props} />;
      }
      const isChecked = checked === true;

      return (
        <input
          {...props}
          type="checkbox"
          checked={isChecked}
          disabled={savingTask}
          aria-label={t(
            isChecked ? "tasks.markIncomplete" : "tasks.markComplete",
          )}
          onChange={(event) =>
            void commitTask(lineIndex, {
              checked: event.target.checked,
              completedOn: event.target.checked ? localISODate() : null,
            })
          }
        />
      );
    };
    components.li = ({ node, className, children: itemChildren, ...props }) => {
      const taskListItem = className?.split(" ").includes("task-list-item");
      if (!taskListItem) {
        return (
          <li className={className} {...props}>
            {itemChildren}
          </li>
        );
      }

      const lineIndex = node?.properties.dataTaskLine;
      const taskChecked = node?.properties.dataTaskChecked === true;
      const completedOn = node?.properties.dataCompletedOn;
      return (
        <li className={className} {...props}>
          {itemChildren}
          {typeof lineIndex === "number" && taskChecked && (
            <input
              type="date"
              className="ch-task-completed-on"
              value={typeof completedOn === "string" ? completedOn : ""}
              disabled={savingTask}
              aria-label={t("tasks.completedOn")}
              onInput={(event) =>
                void commitTask(lineIndex, {
                  checked: true,
                  completedOn: event.currentTarget.value || null,
                })
              }
            />
          )}
        </li>
      );
    };
  }

  return (
    <div className="ch-prose" aria-busy={savingTask || undefined}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[
          ...(interactive ? [rehypeMarkdownTaskControls] : []),
          rehypeTodoChip,
        ]}
        components={components}
      >
        {interactive ? draft : children}
      </ReactMarkdown>
    </div>
  );
});
