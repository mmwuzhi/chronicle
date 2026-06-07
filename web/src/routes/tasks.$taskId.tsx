import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useTranslation } from "react-i18next";
import { useGetTask, useListProjects } from "../api";
import { Nav } from "../components/nav";
import { TaskLog } from "../components/TaskLog";
import { TaskOverview } from "../components/TaskOverview";

export const Route = createFileRoute("/tasks/$taskId")({
  component: TaskDetail,
});

function TaskDetail() {
  const { t } = useTranslation("tasks");
  const { t: tc } = useTranslation("common");
  const { taskId } = Route.useParams();
  const navigate = useNavigate();
  const taskQuery = useGetTask(taskId);
  const { data: projects } = useListProjects();
  const activeProjects = (projects ?? []).filter(
    (project) => !project.archived,
  );

  if (taskQuery.error) {
    if (taskQuery.error.status === 401) {
      void navigate({ to: "/login" });
      return null;
    }
    return <div className="ch-page-error">{t("detail.failedToLoad")}</div>;
  }

  return (
    <>
      <Nav />
      <main className="ch-page-shell">
        <div className="ch-task-back">
          <Link to="/tasks" className="ch-btn ch-btn-ghost ch-btn-sm">
            ← {t("title")}
          </Link>
        </div>
        {taskQuery.isLoading && <p className="ch-meta">{tc("loading")}</p>}
        {taskQuery.data && (
          <>
            <TaskOverview task={taskQuery.data} projects={activeProjects} />
            <TaskLog taskId={taskId} />
          </>
        )}
      </main>
    </>
  );
}
