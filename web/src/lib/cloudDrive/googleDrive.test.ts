import { describe, expect, it, vi } from "vitest";
import {
  createGoogleDriveAdapter,
  MAX_CLOUD_FILE_BYTES,
} from "@/lib/cloudDrive/googleDrive";
import { isCloudDriveError } from "@/lib/cloudDrive/types";

type MockFetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

function fileOf(name = "notes.pdf", type = "application/pdf"): File {
  return new File(["hello"], name, { type });
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("google drive adapter", () => {
  it("rejects missing Google client id", async () => {
    const adapter = createGoogleDriveAdapter({
      clientId: "",
      deps: {
        requestAccessToken: async () => "token",
      },
    });

    await expect(
      adapter.upload(fileOf(), "operation-id"),
    ).rejects.toMatchObject({
      code: "missing_client_id",
    });
  });

  it("rejects files over the v1 limit before auth", async () => {
    const requestAccessToken = vi.fn(async () => "token");
    const file = fileOf("large.bin", "application/octet-stream");
    Object.defineProperty(file, "size", {
      value: MAX_CLOUD_FILE_BYTES + 1,
    });
    const adapter = createGoogleDriveAdapter({
      clientId: "client-id",
      deps: { requestAccessToken },
    });

    await expect(adapter.upload(file, "operation-id")).rejects.toMatchObject({
      code: "file_too_large",
    });
    expect(requestAccessToken).not.toHaveBeenCalled();
  });

  it("surfaces auth failures as cloud drive errors", async () => {
    const adapter = createGoogleDriveAdapter({
      clientId: "client-id",
      deps: {
        requestAccessToken: async () => {
          throw new Error("popup closed");
        },
      },
    });

    await expect(
      adapter.upload(fileOf(), "operation-id"),
    ).rejects.toMatchObject({
      code: "auth_failed",
    });
  });

  it("uploads into the Chronicle folder and maps the reference", async () => {
    const fetcher = vi
      .fn<MockFetcher>()
      .mockResolvedValueOnce(jsonResponse({ files: [{ id: "folder-id" }] }))
      .mockResolvedValueOnce(jsonResponse({ files: [] }))
      .mockResolvedValueOnce(
        jsonResponse({
          id: "file-id",
          name: "notes.pdf",
          mimeType: "application/pdf",
          webViewLink: "https://drive.google.com/file/d/file-id/view",
        }),
      );
    const adapter = createGoogleDriveAdapter({
      clientId: "client-id",
      deps: {
        fetcher,
        requestAccessToken: async () => "token",
      },
    });

    const attachment = await adapter.upload(fileOf(), "operation-id");

    expect(fetcher).toHaveBeenCalledTimes(3);
    const uploadBody = fetcher.mock.calls[2]?.[1]?.body;
    expect(uploadBody).toBeInstanceOf(Blob);
    await expect((uploadBody as Blob).text()).resolves.toContain(
      '"chronicleOperationId":"operation-id"',
    );
    expect(attachment).toEqual({
      provider: "google_drive",
      providerFileId: "file-id",
      name: "notes.pdf",
      mimeType: "application/pdf",
      sizeBytes: 5,
      webUrl: "https://drive.google.com/file/d/file-id/view",
    });
  });

  it("reuses a Drive file from an ambiguous earlier upload", async () => {
    const fetcher = vi
      .fn<MockFetcher>()
      .mockResolvedValueOnce(jsonResponse({ files: [{ id: "folder-id" }] }))
      .mockResolvedValueOnce(
        jsonResponse({
          files: [
            {
              id: "existing-file",
              name: "notes.pdf",
              mimeType: "application/pdf",
              webViewLink: "https://drive.google.com/file/d/existing-file/view",
            },
          ],
        }),
      );
    const adapter = createGoogleDriveAdapter({
      clientId: "client-id",
      deps: {
        fetcher,
        requestAccessToken: async () => "token",
      },
    });

    const attachment = await adapter.upload(fileOf(), "same-operation");

    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(String(fetcher.mock.calls[1]?.[0])).toContain(
      "chronicleOperationId",
    );
    expect(attachment.providerFileId).toBe("existing-file");
  });

  it("normalizes Google upload failures", async () => {
    const fetcher = vi
      .fn<MockFetcher>()
      .mockResolvedValueOnce(jsonResponse({ files: [{ id: "folder-id" }] }))
      .mockResolvedValueOnce(jsonResponse({ files: [] }))
      .mockResolvedValueOnce(jsonResponse({ error: "nope" }, 500));
    const adapter = createGoogleDriveAdapter({
      clientId: "client-id",
      deps: {
        fetcher,
        requestAccessToken: async () => "token",
      },
    });

    try {
      await adapter.upload(fileOf(), "operation-id");
      throw new Error("expected upload to fail");
    } catch (error) {
      expect(isCloudDriveError(error)).toBe(true);
      if (isCloudDriveError(error)) {
        expect(error.code).toBe("upload_failed");
      }
    }
  });
});
