import { useTranslation } from "react-i18next";
import type { ProjectBody } from "../api";
import { Markdown } from "./Markdown";

interface PromoteCaptureDialogProps {
  rawText: string;
  projects: ProjectBody[];
  projectId: string;
  pending: boolean;
  onProjectChange: (projectId: string) => void;
  onCancel: () => void;
  onConfirm: () => void;
}

export function PromoteCaptureDialog({
  rawText,
  projects,
  projectId,
  pending,
  onProjectChange,
  onCancel,
  onConfirm,
}: PromoteCaptureDialogProps): React.JSX.Element {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");

  return (
    <div className="ch-dialog-backdrop">
      <div className="ch-card ch-promote-dialog">
        <h2 className="ch-dialog-title">{t("promoteDialog.title")}</h2>
        <div className="ch-muted-copy">
          <Markdown>{rawText}</Markdown>
        </div>
        <div className="ch-field-stack">
          <label className="ch-field-label">{t("promoteDialog.project")}</label>
          <select
            value={projectId}
            onChange={(event) => onProjectChange(event.target.value)}
            className="ch-input ch-select-input"
          >
            <option value="">{tc("noProject")}</option>
            {projects.map((project) => (
              <option key={project.id} value={project.id}>
                {project.name}
              </option>
            ))}
          </select>
        </div>
        <div className="ch-dialog-actions">
          <button className="ch-btn ch-btn-sm" onClick={onCancel}>
            {tc("actions.cancel")}
          </button>
          <button
            className="ch-btn ch-btn-primary ch-btn-sm"
            onClick={onConfirm}
            disabled={pending}
          >
            {t("promoteDialog.confirm")}
          </button>
        </div>
      </div>
    </div>
  );
}
