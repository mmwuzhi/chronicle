import { describe, expect, it } from "vitest";
import { rehypeTodoChip } from "@/utils/rehype-todo-chip";
import { trailingTagToken } from "@/utils/todo";

interface Node {
  type: string;
  tagName?: string;
  value?: string;
  children?: Node[];
  properties?: Record<string, unknown>;
}

function p(...children: Node[]): Node {
  return {
    type: "root",
    children: [{ type: "element", tagName: "p", children }],
  };
}

function text(value: string): Node {
  return { type: "text", value };
}

function run(tree: Node): Node {
  rehypeTodoChip()(tree);
  return tree;
}

describe("rehypeTodoChip", () => {
  it("wraps a standalone #todo token in a chip", () => {
    const tree = run(p(text("买牛奶 #todo")));
    const children = tree.children![0].children!;
    expect(children).toHaveLength(2);
    expect(children[0]).toEqual(text("买牛奶 "));
    expect(children[1].tagName).toBe("span");
    expect(children[1].properties?.className).toEqual(["ch-todo-chip"]);
    expect(children[1].children![0].value).toBe("#todo");
  });

  it("marks a done tag and keeps the raw token in the tooltip", () => {
    const tree = run(p(text("买牛奶 #todo(done:2026-07-09)")));
    const chip = tree.children![0].children![1];
    expect(chip.properties?.className).toEqual(["ch-todo-chip", "done"]);
    expect(chip.properties?.title).toBe("#todo(done:2026-07-09)");
    expect(chip.children![0].value).toBe("#todo ✓");
  });

  it("leaves foreign tags and url fragments alone", () => {
    for (const s of ["see #todo-list", "#todo买牛奶", "https://x.com/#todo"]) {
      const tree = run(p(text(s)));
      expect(tree.children![0].children!).toEqual([text(s)]);
    }
  });

  it("does not touch code subtrees", () => {
    const tree = run(
      p({
        type: "element",
        tagName: "code",
        children: [text("grep '#todo'")],
      }),
    );
    expect(tree.children![0].children![0].children![0].value).toBe(
      "grep '#todo'",
    );
  });
});

describe("trailingTagToken", () => {
  it("returns the #-token being typed at the end", () => {
    expect(trailingTagToken("买牛奶 #")).toBe("#");
    expect(trailingTagToken("买牛奶 #to")).toBe("#to");
    expect(trailingTagToken("#todo")).toBe("#todo");
  });

  it("returns null when the text does not end in a tag token", () => {
    expect(trailingTagToken("买牛奶")).toBeNull();
    expect(trailingTagToken("买牛奶 #todo ")).toBeNull();
    expect(trailingTagToken("url/#todo")).toBeNull();
  });
});
