import { useTranslation } from "react-i18next";
import { useNavigate } from "@tanstack/react-router";
import { useDeleteAccount } from "../../api";
import { useConfirm } from "../confirm-dialog";

export function DangerSection() {
  const { t } = useTranslation("settings");
  const navigate = useNavigate();
  const confirm = useConfirm();

  const deleteMutation = useDeleteAccount({
    mutation: {
      onSuccess: () => {
        localStorage.removeItem("access_token");
        navigate({ to: "/" });
      },
    },
  });

  const handleDelete = async () => {
    const ok = await confirm({
      title: t("danger.confirmTitle"),
      description: t("danger.confirmDescription"),
      confirmLabel: t("danger.confirmLabel"),
      variant: "danger",
    });
    if (ok) deleteMutation.mutate();
  };

  return (
    <>
      <h2 className="text-lg font-semibold">{t("danger.title")}</h2>

      <div className="divide-y divide-gray-100">
        <div className="flex items-center justify-between py-4">
          <div>
            <p className="text-sm">{t("danger.deleteDescription")}</p>
          </div>
          <button
            onClick={handleDelete}
            disabled={deleteMutation.isPending}
            className="text-sm px-3 py-1.5 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors shrink-0 ml-8"
          >
            {deleteMutation.isPending
              ? t("danger.deleting")
              : t("danger.deleteAccount")}
          </button>
        </div>
        {deleteMutation.isError && (
          <p className="py-4 text-sm text-red-500">
            {t("danger.deleteFailed")}
          </p>
        )}
      </div>
    </>
  );
}
