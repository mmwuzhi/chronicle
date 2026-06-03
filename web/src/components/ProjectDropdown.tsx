import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import type { ProjectBody } from "../api";

interface Props {
  value: string | null;
  projects: ProjectBody[];
  onChange: (id: string | null) => void;
}

export function ProjectDropdown({ value, projects, onChange }: Props) {
  const { t: tc } = useTranslation("common");
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const selected = value ? projects.find((p) => p.id === value) ?? null : null;

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  return (
    <div ref={ref} style={{ position: "relative", display: "inline-block" }}>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          padding: "4px 10px",
          borderRadius: "var(--radius-pill)",
          border: "1px solid var(--border)",
          background: "var(--surface)",
          cursor: "pointer",
          fontSize: "var(--fs-sm)",
          color: "var(--text)",
          transition: "border-color 0.14s",
        }}
      >
        <span
          style={{
            width: 8,
            height: 8,
            borderRadius: "50%",
            background: selected ? selected.color : "var(--text-faint)",
            flexShrink: 0,
          }}
        />
        {selected ? selected.name : tc("noProject")}
      </button>

      {open && (
        <div
          style={{
            position: "absolute",
            top: "calc(100% + 4px)",
            left: 0,
            zIndex: 100,
            background: "var(--surface)",
            border: "1px solid var(--border)",
            borderRadius: "var(--radius-sm)",
            boxShadow: "var(--shadow-lg)",
            padding: 4,
            minWidth: 160,
            animation: "ch-fade 0.1s ease",
          }}
        >
          <button
            type="button"
            onClick={() => { onChange(null); setOpen(false); }}
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              width: "100%",
              padding: "8px 12px",
              fontSize: "var(--fs-sm)",
              color: value === null ? "var(--accent-strong)" : "var(--text-muted)",
              background: "transparent",
              border: "none",
              borderRadius: 6,
              cursor: "pointer",
              textAlign: "left",
              fontWeight: value === null ? 600 : 400,
            }}
          >
            <span
              style={{
                width: 8,
                height: 8,
                borderRadius: "50%",
                background: "var(--text-faint)",
                flexShrink: 0,
              }}
            />
            {tc("noProject")}
          </button>
          {projects.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => { onChange(p.id); setOpen(false); }}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                width: "100%",
                padding: "8px 12px",
                fontSize: "var(--fs-sm)",
                color: value === p.id ? "var(--accent-strong)" : "var(--text)",
                background: "transparent",
                border: "none",
                borderRadius: 6,
                cursor: "pointer",
                textAlign: "left",
                fontWeight: value === p.id ? 600 : 400,
              }}
            >
              <span
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: "50%",
                  background: p.color,
                  flexShrink: 0,
                }}
              />
              {p.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
