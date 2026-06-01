import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useListProjects, useListTasks, useListTimeBlocks } from "../api";
import type { TaskBody } from "../api";
import { Nav } from "../components/nav";
import { ProjectHeader } from "../components/ProjectHeader";
import { TaskComposer } from "../components/TaskComposer";
import { ProjectTaskList } from "../components/ProjectTaskList";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/projects/$projectId")({
  component: ProjectDetail,
});

function ProjectDetail() {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const { projectId } = Route.useParams();
  const navigate = useNavigate();

  const {
    data: projects,
    isLoading: projectsLoading,
    error: projectsError,
  } = useListProjects();
  const project = projects?.find((p) => p.id === projectId);

  const { data: tasks } = useListTasks({ projectId });
  const { data: timeBlocks } = useListTimeBlocks();

  if (projectsError) {
    const status = (projectsError as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("detail.failedToLoad")}</div>;
  }

  if (projectsLoading) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8">
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        </div>
      </div>
    );
  }

  if (!project) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Nav />
        <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-4">
          <p className="text-gray-500 text-sm">{t("detail.notFound")}</p>
          <a
            href="/projects"
            className="text-sm text-gray-900 font-medium hover:underline"
          >
            {t("detail.backToProjects")}
          </a>
        </div>
      </div>
    );
  }

  const taskIds = new Set((tasks ?? []).map((t: TaskBody) => t.id));
  const totalSec = (timeBlocks ?? [])
    .filter((b) => b.taskId !== null && taskIds.has(b.taskId))
    .reduce((s, b) => s + (b.durationSec ?? 0), 0);

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-4 md:px-8 py-6 md:py-8 flex flex-col gap-6">
        <ProjectHeader
          project={project}
          projectId={projectId}
          totalSec={totalSec}
        />
        <TaskComposer projectId={projectId} />
        <ProjectTaskList projectId={projectId} />
      </div>
    </div>
  );
}
