import { useState } from "react";
import type { AxiosError } from "axios";
import { useTranslation } from "react-i18next";
import { type ErrorModel, type ImportResult, useImportArchive } from "@/api";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { FieldError, FieldLabel, Input } from "@/components/ui/field";
import { Meta } from "@/components/ui/page";
import { apiFetch } from "@/lib/apiFetch";

const maxBufferedArchiveBytes = 256 * 1024 * 1024;

function archiveFilename(): string {
  return `chronicle-${new Date().toISOString().replaceAll(":", "-")}.zip`;
}

function apiErrorMessage(error: AxiosError<ErrorModel>): string | null {
  return error.response?.data.detail ?? error.response?.data.title ?? null;
}

async function boundedArchiveBlob(response: Response): Promise<Blob> {
  if (!response.body) throw new Error("archive body is missing");
  const contentLength = Number(response.headers.get("Content-Length"));
  if (
    Number.isFinite(contentLength) &&
    contentLength > maxBufferedArchiveBytes
  ) {
    throw new Error("browser cannot buffer this archive");
  }
  const reader = response.body.getReader();
  const chunks: BlobPart[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maxBufferedArchiveBytes) {
      await reader.cancel();
      throw new Error("browser cannot buffer this archive");
    }
    chunks.push(value.slice());
  }
  return new Blob(chunks, {
    type: response.headers.get("Content-Type") ?? "application/zip",
  });
}

function ResultSummary({
  result,
}: {
  result: ImportResult;
}): React.JSX.Element {
  const { t } = useTranslation("settings");
  return (
    <Card className="bg-tint p-4">
      <p className="font-semibold text-ink">{t("data.archive.resultTitle")}</p>
      <Meta className="block">
        {t("data.archive.result", {
          created: result.created,
          skipped: result.skipped,
          forked: result.forked,
          media: result.media,
          links: result.links,
          attachments: result.attachments,
        })}
      </Meta>
      {(result.warnings ?? []).map((warning) => (
        <Meta key={warning} className="mt-1 block text-danger">
          {warning}
        </Meta>
      ))}
    </Card>
  );
}

export function DataPortabilitySection(): React.JSX.Element {
  const { t } = useTranslation("settings");
  const [file, setFile] = useState<File | null>(null);
  const [operationID, setOperationID] = useState(() => crypto.randomUUID());
  const [result, setResult] = useState<ImportResult | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState(false);
  const restore = useImportArchive<AxiosError<ErrorModel>>({
    request: {
      headers: {
        "Idempotency-Key": operationID,
      },
    },
    mutation: {
      onSuccess: (value) => {
        setResult(value);
        setImportError(null);
      },
      onError: (error) => {
        setImportError(
          apiErrorMessage(error) ?? t("data.archive.importFailed"),
        );
      },
    },
  });

  const download = async (): Promise<void> => {
    setExporting(true);
    setExportError(false);
    try {
      const picker = (
        window as Window & {
          showSaveFilePicker?: (options: {
            suggestedName: string;
            types: Array<{
              description: string;
              accept: Record<string, string[]>;
            }>;
          }) => Promise<{
            createWritable: () => Promise<WritableStream<Uint8Array>>;
          }>;
        }
      ).showSaveFilePicker;
      // Ask while the click's transient activation is still live. Waiting for
      // a large export response first makes Chromium reject the picker.
      const handle =
        picker && !navigator.webdriver
          ? await picker({
              suggestedName: archiveFilename(),
              types: [
                {
                  description: "Chronicle archive",
                  accept: { "application/zip": [".zip"] },
                },
              ],
            })
          : null;
      const response = await apiFetch("/archive/export", {
        headers: { Accept: "application/zip" },
      });
      if (!response.ok || !response.body) throw new Error("export failed");
      if (handle) {
        await response.body.pipeTo(await handle.createWritable());
        return;
      }
      const objectURL = URL.createObjectURL(await boundedArchiveBlob(response));
      const anchor = document.createElement("a");
      anchor.href = objectURL;
      anchor.download = archiveFilename();
      anchor.click();
      URL.revokeObjectURL(objectURL);
    } catch {
      setExportError(true);
    } finally {
      setExporting(false);
    }
  };

  const chooseFile = (next: File | null): void => {
    setFile(next);
    setOperationID(crypto.randomUUID());
    setResult(null);
    setImportError(null);
  };

  const importSelected = (): void => {
    if (!file || !window.confirm(t("data.archive.importConfirm"))) return;
    restore.mutate({ data: file });
  };

  return (
    <Card asChild className="flex flex-col gap-5 p-4">
      <section>
        <div>
          <h2 className="font-app-display text-body font-semibold text-ink">
            {t("data.archive.title")}
          </h2>
          <Meta>{t("data.archive.description")}</Meta>
        </div>

        <div className="flex flex-col gap-2">
          <FieldLabel>{t("data.archive.exportTitle")}</FieldLabel>
          <Meta>{t("data.archive.exportDescription")}</Meta>
          <Button
            className="self-start"
            onClick={() => void download()}
            disabled={exporting}
          >
            {exporting ? t("data.archive.exporting") : t("data.archive.export")}
          </Button>
          {exportError && (
            <FieldError>{t("data.archive.exportFailed")}</FieldError>
          )}
        </div>

        <div className="flex flex-col gap-2 border-t border-hairline pt-4">
          <FieldLabel htmlFor="archive-file">
            {t("data.archive.importTitle")}
          </FieldLabel>
          <Meta>{t("data.archive.importDescription")}</Meta>
          <Input
            id="archive-file"
            type="file"
            accept=".zip,application/zip"
            onChange={(event) =>
              chooseFile(event.currentTarget.files?.[0] ?? null)
            }
          />
          <Button
            className="self-start"
            variant="primary"
            onClick={importSelected}
            disabled={!file || restore.isPending}
          >
            {restore.isPending
              ? t("data.archive.importing")
              : t("data.archive.import")}
          </Button>
          {importError && <FieldError>{importError}</FieldError>}
        </div>

        {result && <ResultSummary result={result} />}
      </section>
    </Card>
  );
}
