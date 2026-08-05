import { useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { AxiosError } from "axios";
import { useTranslation } from "react-i18next";
import {
  type ErrorModel,
  type MarkdownImportResult,
  useImportMarkdown,
  useUndoMarkdownImport,
} from "@/api";
import { MutationToast } from "@/components/mutation-toast";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { FieldError, FieldLabel, Input } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";
import { useMutationToast } from "@/hooks/use-mutation-toast";

function errorMessage(error: AxiosError<ErrorModel>): string | null {
  return error.response?.data.detail ?? error.response?.data.title ?? null;
}

function MarkdownImportResultCard({
  result,
  onUndo,
  undoing,
  undone,
}: {
  result: MarkdownImportResult;
  onUndo: () => void;
  undoing: boolean;
  undone: boolean;
}): React.JSX.Element {
  const { t } = useTranslation("settings");
  return (
    <Card className="bg-tint p-4">
      <p className="font-semibold text-ink">{t("data.markdown.resultTitle")}</p>
      <Meta className="block">
        {t("data.markdown.result", {
          created: result.created,
          skipped: result.skipped,
          links: result.links,
          frontmatter: result.frontmatterApplied,
        })}
      </Meta>
      {result.analysisQueued && (
        <Meta className="mt-1 block">{t("data.markdown.analysis")}</Meta>
      )}
      {result.replayed && (
        <Meta className="mt-1 block">{t("data.markdown.replayed")}</Meta>
      )}
      {(result.issues ?? []).map((issue) => (
        <Meta key={issue.code} className="mt-1 block text-danger">
          {t(`data.markdown.issues.${issue.code}`, {
            count: issue.count,
            defaultValue: t("data.markdown.issueFallback", {
              code: issue.code,
              count: issue.count,
            }),
          })}
          {(issue.examples ?? []).length > 0
            ? ` — ${(issue.examples ?? []).join("; ")}`
            : ""}
        </Meta>
      ))}
      <Button
        className="mt-3"
        size="sm"
        onClick={onUndo}
        disabled={undoing || undone}
      >
        {undone
          ? t("data.markdown.undone")
          : undoing
            ? t("data.markdown.undoing")
            : t("data.markdown.undo")}
      </Button>
    </Card>
  );
}

export function MarkdownImportSection(): React.JSX.Element {
  const { t } = useTranslation("settings");
  const queryClient = useQueryClient();
  const toast = useMutationToast();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [operationID, setOperationID] = useState(() => crypto.randomUUID());
  const [result, setResult] = useState<MarkdownImportResult | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [undone, setUndone] = useState(false);
  const importMutation = useImportMarkdown<AxiosError<ErrorModel>>({
    request: {
      headers: {
        "Idempotency-Key": operationID,
        "X-Import-Filename": file ? encodeURIComponent(file.name) : "",
        "X-Import-Time-Zone":
          Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
      },
    },
    mutation: {
      onSuccess: (value) => {
        void queryClient.invalidateQueries();
        setResult(value);
        setImportError(null);
        setUndone(false);
        setFile(null);
        setOperationID(crypto.randomUUID());
        if (fileInputRef.current) fileInputRef.current.value = "";
      },
      onError: (error) => {
        const message = errorMessage(error) ?? t("data.markdown.importFailed");
        setImportError(message);
        toast.show(message);
      },
    },
  });
  const undoMutation = useUndoMarkdownImport<AxiosError<ErrorModel>>({
    mutation: {
      onSuccess: () => {
        void queryClient.invalidateQueries();
        setUndone(true);
      },
      onError: (error) =>
        toast.show(errorMessage(error) ?? t("data.markdown.undoFailed")),
    },
  });

  const chooseFile = (next: File | null): void => {
    setFile(next);
    setOperationID(crypto.randomUUID());
    setResult(null);
    setImportError(null);
    setUndone(false);
  };
  const importSelected = (): void => {
    if (!file || !window.confirm(t("data.markdown.importConfirm"))) return;
    importMutation.mutate({ data: file });
  };
  const undo = (): void => {
    if (!result || !window.confirm(t("data.markdown.undoConfirm"))) return;
    undoMutation.mutate({ operationId: result.operationId });
  };

  return (
    <div className="flex flex-col gap-2 border-t border-hairline pt-4">
      <FieldLabel htmlFor="markdown-import-file">
        {t("data.markdown.title")}
      </FieldLabel>
      <Meta>{t("data.markdown.description")}</Meta>
      <Meta>{t("data.markdown.formatHint")}</Meta>
      <Input
        ref={fileInputRef}
        id="markdown-import-file"
        type="file"
        accept=".zip,.md,.markdown,.txt,application/zip,text/markdown,text/plain"
        onChange={(event) => chooseFile(event.currentTarget.files?.[0] ?? null)}
      />
      <Button
        className="self-start"
        variant="primary"
        onClick={importSelected}
        disabled={!file || importMutation.isPending}
      >
        {importMutation.isPending
          ? t("data.markdown.importing")
          : t("data.markdown.import")}
      </Button>
      {importError && <FieldError>{importError}</FieldError>}
      {result && (
        <MarkdownImportResultCard
          result={result}
          onUndo={undo}
          undoing={undoMutation.isPending}
          undone={undone}
        />
      )}
      <MutationToast message={toast.message} />
    </div>
  );
}
