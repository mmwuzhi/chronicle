import { useTranslation } from "react-i18next";
import { useNavigate } from "@tanstack/react-router";
import { useDeleteAccount } from "../../api";
import { useConfirm } from "../../hooks/use-confirm";
import { Button } from "../ui/button";
import { FieldError } from "../ui/field";

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
      <h2 className="font-app-display text-[17px] font-semibold text-ink">
        {t("danger.title")}
      </h2>

      <div className="divide-y divide-hairline">
        <div className="flex items-center justify-between py-4">
          <div>
            <p className="text-small text-ink">
              {t("danger.deleteDescription")}
            </p>
          </div>
          <Button
            variant="ghost"
            size="sm"
            onClick={handleDelete}
            disabled={deleteMutation.isPending}
            className="ml-8 shrink-0 text-danger hover:bg-danger-weak hover:text-danger-strong"
          >
            {deleteMutation.isPending
              ? t("danger.deleting")
              : t("danger.deleteAccount")}
          </Button>
        </div>
        {deleteMutation.isError && (
          <FieldError className="py-4 text-small">
            {t("danger.deleteFailed")}
          </FieldError>
        )}
      </div>
    </>
  );
}
