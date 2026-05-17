import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation } from "@tanstack/react-query";
import { Nav } from "../components/nav";
import { useConfirm } from "../components/confirm-dialog";
import { api } from "../lib/axios";

export const Route = createFileRoute("/settings")({
  component: Settings,
});

const deleteAccount = () =>
  api<void>({ url: "/users/me", method: "DELETE" });

function Settings() {
  const navigate = useNavigate();
  const confirm = useConfirm();

  const mutation = useMutation({
    mutationFn: deleteAccount,
    onSuccess: () => {
      localStorage.removeItem("access_token");
      navigate({ to: "/" });
    },
  });

  const handleDelete = async () => {
    const ok = await confirm({
      title: "Delete account",
      description:
        "This will permanently delete your account and all your data. This action cannot be undone.",
      confirmLabel: "Yes, delete",
      variant: "danger",
    });
    if (ok) mutation.mutate();
  };

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-12">
        <h1 className="text-xl font-semibold mb-8">Settings</h1>

        <div className="bg-white rounded-xl border border-gray-200 shadow-sm">
          <div className="p-6 border-b border-gray-100">
            <h2 className="text-sm font-semibold text-red-600">Danger zone</h2>
          </div>
          <div className="p-6 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">Delete account</p>
              <p className="text-xs text-gray-500 mt-0.5">
                Permanently delete your account and all data. This cannot be
                undone.
              </p>
            </div>
            <button
              onClick={handleDelete}
              disabled={mutation.isPending}
              className="text-sm px-4 py-2 rounded-md border border-red-300 text-red-600 hover:bg-red-50 transition-colors disabled:opacity-50"
            >
              {mutation.isPending ? "Deleting…" : "Delete account"}
            </button>
          </div>
          {mutation.isError && (
            <p className="px-6 pb-6 text-sm text-red-500">
              Something went wrong. Please try again.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
