import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useQueryClient } from "@tanstack/react-query";
import {
  useListProjects,
  useCreateProject,
  useUpdateProject,
  getListProjectsQueryKey,
} from "../api";
import { Nav } from "../components/nav";
import { useTranslation } from "react-i18next";

export const Route = createFileRoute("/projects/")({
  component: Projects,
});

const createSchema = z.object({
  name: z.string().min(1, "Name is required"),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/, "Must be a hex color"),
});
type CreateForm = z.infer<typeof createSchema>;

function Projects() {
  const { t } = useTranslation("projects");
  const { t: tc } = useTranslation("common");
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const { data: projects, isLoading, error } = useListProjects();

  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: getListProjectsQueryKey() });

  const create = useCreateProject({ mutation: { onSuccess: invalidate } });
  const update = useUpdateProject({ mutation: { onSuccess: invalidate } });

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CreateForm>({
    resolver: zodResolver(createSchema),
    defaultValues: { color: "#6366f1" },
  });

  if (error) {
    const status = (error as { status?: number }).status;
    if (status === 401) {
      navigate({ to: "/login" });
      return null;
    }
    return <div className="p-8 text-red-500">{t("failedToLoad")}</div>;
  }

  const active = projects?.filter((p) => !p.archived) ?? [];

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-2xl mx-auto p-8 flex flex-col gap-8">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>
        </header>

        <form
          onSubmit={handleSubmit((data) =>
            create.mutate({ data }, { onSuccess: () => reset() }),
          )}
          className="flex gap-2 items-start"
        >
          <div className="flex flex-col gap-1 flex-1">
            <input
              {...register("name")}
              placeholder={t("newProjectName")}
              className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
            />
            {errors.name && (
              <p className="text-red-500 text-xs">{errors.name.message}</p>
            )}
          </div>
          <input
            type="color"
            {...register("color")}
            className="h-[38px] w-10 cursor-pointer rounded border border-gray-300 p-0.5"
            title="Project color"
          />
          <button
            type="submit"
            disabled={create.isPending}
            className="bg-gray-900 text-white rounded-md px-4 py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50 whitespace-nowrap"
          >
            {t("addProject")}
          </button>
        </form>

        {isLoading ? (
          <div className="text-gray-400 text-sm">{tc("loading")}</div>
        ) : (
          <ul className="flex flex-col gap-2">
            {active.map((p) => (
              <li
                key={p.id}
                className="bg-white rounded-lg border border-gray-200 shadow-sm"
              >
                <div className="flex items-center gap-3 p-3">
                  <Link
                    to="/projects/$projectId"
                    params={{ projectId: p.id }}
                    className="flex items-center gap-3 flex-1 hover:opacity-70 transition-opacity"
                  >
                    <span
                      className="w-3 h-3 rounded-full shrink-0"
                      style={{ backgroundColor: p.color }}
                    />
                    <span className="text-sm font-medium">{p.name}</span>
                  </Link>
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      update.mutate({ id: p.id, data: { archived: true } });
                    }}
                    className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
                  >
                    {tc("actions.archive")}
                  </button>
                </div>
              </li>
            ))}
            {active.length === 0 && (
              <p className="text-gray-400 text-sm">
                {t("noProjects")}
              </p>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}
