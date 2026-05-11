import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import {
  useListCaptures,
  useCreateCapture,
  useUpdateCapture,
  useDeleteCapture,
} from "../api";
import type { CaptureBody, CaptureUpdateInputBodyClassifiedAs } from "../api";
import { Nav } from "../components/nav";

export const Route = createFileRoute("/captures")({
  component: Captures,
});

type Tab = "all" | "unclassified" | "idea" | "task";

const TABS: { id: Tab; label: string }[] = [
  { id: "all", label: "All" },
  { id: "unclassified", label: "Unclassified" },
  { id: "idea", label: "Ideas" },
  { id: "task", label: "Tasks" },
];

const CLASS_LABELS: Record<string, string> = {
  unclassified: "Unclassified",
  idea: "Idea",
  task: "Task",
  routine: "Routine",
  log: "Log",
};

const CLASS_COLORS: Record<string, string> = {
  unclassified: "bg-gray-100 text-gray-500",
  idea: "bg-purple-100 text-purple-700",
  task: "bg-blue-100 text-blue-700",
  routine: "bg-green-100 text-green-700",
  log: "bg-yellow-100 text-yellow-700",
};

const RECLASSIFY_OPTIONS: CaptureUpdateInputBodyClassifiedAs[] = [
  "unclassified",
  "idea",
  "task",
  "routine",
  "log",
];

function Captures() {
  const navigate = useNavigate();
  const [tab, setTab] = useState<Tab>("all");
  const [text, setText] = useState("");

  const params = tab === "all" ? undefined : { classifiedAs: tab };
  const { data: captures, error, isLoading } = useListCaptures(params);

  const create = useCreateCapture();
  const update = useUpdateCapture();
  const del = useDeleteCapture();

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">Failed to load captures</div>;
  }

  const handleAdd = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    create.mutate(
      {
        data: {
          rawText: trimmed,
          mediaType: "text",
          classifiedAs: "unclassified",
        },
      },
      { onSuccess: () => setText("") },
    );
  };

  const handleReclassify = (
    id: string,
    classifiedAs: CaptureUpdateInputBodyClassifiedAs,
  ) => {
    update.mutate({ id, data: { classifiedAs } });
  };

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-8 flex flex-col gap-6">
        <h1 className="text-2xl font-semibold tracking-tight">Captures</h1>

        {/* Quick add */}
        <div className="flex gap-2">
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                handleAdd();
              }
            }}
            placeholder="Capture a thought… (Enter to save)"
            rows={2}
            className="flex-1 border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900 resize-none"
          />
          <button
            onClick={handleAdd}
            disabled={create.isPending || !text.trim()}
            className="self-end bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
          >
            Save
          </button>
        </div>

        {/* Tabs */}
        <div className="flex gap-1">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                tab === t.id
                  ? "bg-gray-900 text-white"
                  : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        {/* List */}
        {isLoading ? (
          <div className="text-gray-400 text-sm">Loading…</div>
        ) : (
          <ul className="flex flex-col gap-2">
            {(captures ?? []).map((c: CaptureBody) => (
              <li
                key={c.id}
                className="bg-white rounded-lg border border-gray-200 shadow-sm p-4 flex flex-col gap-3"
              >
                <p className="text-sm">{c.rawText}</p>
                <div className="flex items-center gap-2">
                  <select
                    value={c.classifiedAs}
                    onChange={(e) =>
                      handleReclassify(
                        c.id,
                        e.target.value as CaptureUpdateInputBodyClassifiedAs,
                      )
                    }
                    className={`text-xs font-medium px-2 py-1 rounded-full border-0 cursor-pointer ${CLASS_COLORS[c.classifiedAs] ?? "bg-gray-100 text-gray-500"}`}
                  >
                    {RECLASSIFY_OPTIONS.map((opt) => (
                      <option key={opt} value={opt}>
                        {CLASS_LABELS[opt]}
                      </option>
                    ))}
                  </select>
                  <span className="flex-1" />
                  <button
                    onClick={() => del.mutate({ id: c.id })}
                    className="text-xs text-gray-400 hover:text-red-500 transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </li>
            ))}
            {(captures ?? []).length === 0 && (
              <p className="text-gray-400 text-sm">Nothing here yet.</p>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}
