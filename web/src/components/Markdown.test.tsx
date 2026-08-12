import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { Markdown } from "@/components/Markdown";

describe("Markdown task list controls", () => {
  it("renders editable task checkboxes when a save handler is present", () => {
    const html = renderToStaticMarkup(
      <Markdown onTaskChange={async () => {}}>- [ ] test</Markdown>,
    );

    expect(html).toContain('type="checkbox"');
    expect(html).not.toContain("disabled");
  });

  it("renders stored completion metadata as an editable date", () => {
    const html = renderToStaticMarkup(
      <Markdown onTaskChange={async () => {}}>
        - [x] test ✅ 2026-08-13
      </Markdown>,
    );

    expect(html).toContain('type="date"');
    expect(html).toContain('value="2026-08-13"');
    expect(html).not.toContain("✅ 2026-08-13");
  });

  it("uses parsed task lines instead of task-like text in code blocks", () => {
    const html = renderToStaticMarkup(
      <Markdown onTaskChange={async () => {}}>
        {"```txt\n- [ ] sample\n```\n\n- [x] real ✅ 2026-08-13"}
      </Markdown>,
    );

    expect(html.match(/type="checkbox"/g)).toHaveLength(1);
    expect(html).toContain("- [ ] sample");
    expect(html).toContain('checked=""');
    expect(html).toContain('type="date"');
    expect(html).toContain('value="2026-08-13"');
  });

  it("renders quoted tasks as interactive controls", () => {
    const html = renderToStaticMarkup(
      <Markdown onTaskChange={async () => {}}>
        {"> - [x] quoted ✅ 2026-08-12"}
      </Markdown>,
    );

    expect(html).toContain('type="checkbox"');
    expect(html).toContain('value="2026-08-12"');
    expect(html).not.toContain("disabled");
  });

  it("keeps task checkboxes read-only without a save handler", () => {
    const html = renderToStaticMarkup(<Markdown>- [ ] test</Markdown>);

    expect(html).toContain('type="checkbox"');
    expect(html).toContain("disabled");
  });
});
