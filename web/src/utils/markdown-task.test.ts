import { describe, expect, it } from "vitest";

import { localISODate, updateMarkdownTask } from "@/utils/markdown-task";

describe("markdown task lists", () => {
  it("checks a task by source line and appends its completion date", () => {
    expect(
      updateMarkdownTask("- [ ] first\n- [ ] second", 1, {
        checked: true,
        completedOn: "2026-08-13",
      }),
    ).toBe("- [ ] first\n- [x] second ✅ 2026-08-13");
  });

  it("changes or removes completion metadata with the task state", () => {
    const completed = "- [x] first ✅ 2026-08-12";
    expect(
      updateMarkdownTask(completed, 0, {
        checked: true,
        completedOn: "2026-08-13",
      }),
    ).toBe("- [x] first ✅ 2026-08-13");
    expect(
      updateMarkdownTask(completed, 0, {
        checked: false,
        completedOn: null,
      }),
    ).toBe("- [ ] first");
  });

  it("updates nested and quoted task markers without touching other lines", () => {
    expect(
      updateMarkdownTask("```txt\n- [ ] sample\n```\n\n> - [ ] quoted", 4, {
        checked: true,
        completedOn: "2026-08-13",
      }),
    ).toBe("```txt\n- [ ] sample\n```\n\n> - [x] quoted ✅ 2026-08-13");
  });

  it("leaves non-task lines and malformed dates unchanged", () => {
    const markdown = "paragraph\n- [x] keep ✅ 2026-02-30";
    expect(
      updateMarkdownTask(markdown, 0, {
        checked: false,
        completedOn: null,
      }),
    ).toBe(markdown);
    expect(
      updateMarkdownTask(markdown, 1, {
        checked: true,
        completedOn: null,
      }),
    ).toBe(markdown);
  });

  it("formats a date in local calendar time", () => {
    expect(localISODate(new Date(2026, 7, 3, 23, 30))).toBe("2026-08-03");
  });
});
