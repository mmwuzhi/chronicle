const TASK_LINE_RE =
  /^((?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:(?:[-+*])|(?:\d+[.)]))[ \t]+\[)([ xX])(\])(?=[ \t]|$)(.*)$/;
const COMPLETION_DATE_RE = /[ \t]+✅[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$/;

export interface MarkdownTask {
  checked: boolean;
  completedOn: string | null;
}

interface HastPosition {
  start: { line: number };
}

interface HastNode {
  type: string;
  tagName?: string;
  value?: string;
  children?: HastNode[];
  properties?: Record<string, unknown>;
  position?: HastPosition;
}

export function updateMarkdownTask(
  markdown: string,
  lineIndex: number,
  update: MarkdownTask,
): string {
  const parts = markdown.split(/(\r?\n)/);
  if (!Number.isInteger(lineIndex) || lineIndex < 0) return markdown;
  const partIndex = lineIndex * 2;
  const line = parts[partIndex];
  if (line === undefined) return markdown;

  const match = TASK_LINE_RE.exec(line);
  if (!match) return markdown;

  const completion = COMPLETION_DATE_RE.exec(match[4]);
  const content =
    completion && isCalendarDate(completion[1])
      ? match[4].slice(0, completion.index)
      : match[4];
  const completedOn =
    update.checked && update.completedOn && isCalendarDate(update.completedOn)
      ? ` ✅ ${update.completedOn}`
      : "";
  parts[partIndex] =
    `${match[1]}${update.checked ? "x" : " "}${match[3]}${content}${completedOn}`;

  return parts.join("");
}

export function rehypeMarkdownTaskControls() {
  return (tree: unknown): void => {
    walkTaskItems(tree as HastNode);
  };
}

function walkTaskItems(node: HastNode): void {
  if (isTaskListItem(node)) decorateTaskItem(node);
  node.children?.forEach(walkTaskItems);
}

function isTaskListItem(node: HastNode): boolean {
  if (node.tagName !== "li") return false;
  const className = node.properties?.className;
  return (
    Array.isArray(className) &&
    className.some((value) => value === "task-list-item")
  );
}

function decorateTaskItem(item: HastNode): void {
  const line = item.position?.start.line;
  const content = taskItemContent(item);
  const checkbox = findCheckbox(content);
  if (!line || !checkbox) return;

  const lineIndex = line - 1;
  const checkboxProperties = checkbox.properties ?? {};
  const checked = checkboxProperties.checked === true;
  item.properties = {
    ...item.properties,
    dataTaskLine: lineIndex,
    dataTaskChecked: checked,
  };
  checkbox.properties = {
    ...checkboxProperties,
    dataTaskLine: lineIndex,
  };

  if (!checked) return;
  const text = findLastTaskLineText(content, line);
  if (!text?.value) return;
  const completion = COMPLETION_DATE_RE.exec(text.value);
  if (!completion || !isCalendarDate(completion[1])) return;

  text.value = text.value.slice(0, completion.index);
  item.properties.dataCompletedOn = completion[1];
}

function taskItemContent(item: HastNode): HastNode {
  const paragraph = item.children?.find((child) => child.tagName === "p");
  return paragraph ?? item;
}

function findCheckbox(node: HastNode): HastNode | undefined {
  if (node.tagName === "input" && node.properties?.type === "checkbox") {
    return node;
  }
  if (node.tagName === "ul" || node.tagName === "ol") return undefined;
  for (const child of node.children ?? []) {
    const checkbox = findCheckbox(child);
    if (checkbox) return checkbox;
  }
  return undefined;
}

function findLastTaskLineText(
  node: HastNode,
  line: number,
): HastNode | undefined {
  if (
    node.type === "text" &&
    node.position?.start.line === line &&
    node.value?.trim()
  ) {
    return node;
  }
  if (
    node.tagName === "ul" ||
    node.tagName === "ol" ||
    node.tagName === "code" ||
    node.tagName === "pre"
  ) {
    return undefined;
  }
  const children = node.children ?? [];
  for (let index = children.length - 1; index >= 0; index -= 1) {
    const text = findLastTaskLineText(children[index], line);
    if (text) return text;
  }
  return undefined;
}

export function localISODate(date: Date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function isCalendarDate(value: string): boolean {
  const [year, month, day] = value.split("-").map(Number);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return (
    parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day
  );
}
