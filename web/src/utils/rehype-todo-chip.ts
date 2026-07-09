import { TODO_TAG_RE } from "./todo";

// Rehype plugin: render the #todo system tag as a chip. Walks the hast tree
// after remark→rehype, splits text nodes on the tag grammar (shared with the
// API via TODO_TAG_RE), and wraps each token in
// <span class="ch-todo-chip [done]" title="…">#todo</span>. The chip shows the
// compact "#todo" label; a done parameter moves to the title tooltip so the
// card stays quiet. Code and pre subtrees are skipped — a tag inside a code
// sample is content, not state.

interface HastNode {
  type: string;
  tagName?: string;
  value?: string;
  children?: HastNode[];
  properties?: Record<string, unknown>;
}

const TAG_GLOBAL = new RegExp(TODO_TAG_RE.source, "gu");

function chipFor(token: string, param: string | undefined): HastNode {
  return {
    type: "element",
    tagName: "span",
    properties: {
      className: ["ch-todo-chip", ...(param ? ["done"] : [])],
      ...(param ? { title: token } : {}),
    },
    children: [{ type: "text", value: param ? "#todo ✓" : "#todo" }],
  };
}

function splitTextNode(node: HastNode): HastNode[] | null {
  const value = node.value ?? "";
  const out: HastNode[] = [];
  let last = 0;
  TAG_GLOBAL.lastIndex = 0;
  for (let m = TAG_GLOBAL.exec(value); m !== null; m = TAG_GLOBAL.exec(value)) {
    const tokenStart = m.index + m[1].length;
    if (tokenStart > last)
      out.push({ type: "text", value: value.slice(last, tokenStart) });
    out.push(chipFor(m[2], m[3]));
    last = tokenStart + m[2].length;
  }
  if (out.length === 0) return null;
  if (last < value.length) out.push({ type: "text", value: value.slice(last) });
  return out;
}

function walk(node: HastNode): void {
  if (node.tagName === "code" || node.tagName === "pre") return;
  const children = node.children;
  if (!children) return;
  for (let i = children.length - 1; i >= 0; i--) {
    const child = children[i];
    if (child.type === "text") {
      const replaced = splitTextNode(child);
      if (replaced) children.splice(i, 1, ...replaced);
    } else {
      walk(child);
    }
  }
}

export function rehypeTodoChip() {
  return (tree: unknown) => {
    walk(tree as HastNode);
  };
}
