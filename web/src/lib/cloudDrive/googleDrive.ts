import type {
  CloudAttachmentDraft,
  CloudDriveProviderAdapter,
} from "@/lib/cloudDrive/types";
import { CloudDriveError } from "@/lib/cloudDrive/types";

export const GOOGLE_DRIVE_FILE_SCOPE =
  "https://www.googleapis.com/auth/drive.file";
export const MAX_CLOUD_FILE_BYTES = 100 * 1024 * 1024;

const GOOGLE_IDENTITY_SCRIPT_URL = "https://accounts.google.com/gsi/client";
const DRIVE_API_BASE_URL = "https://www.googleapis.com/drive/v3";
const DRIVE_UPLOAD_BASE_URL = "https://www.googleapis.com/upload/drive/v3";
const CHRONICLE_FOLDER_NAME = "Chronicle";
const DEFAULT_MIME_TYPE = "application/octet-stream";

interface GoogleTokenResponse {
  access_token?: string;
  error?: string;
  error_description?: string;
}

interface GoogleTokenClient {
  requestAccessToken: (overrideConfig?: { prompt?: string }) => void;
}

interface GoogleOAuth2 {
  initTokenClient: (config: {
    client_id: string;
    scope: string;
    callback: (response: GoogleTokenResponse) => void;
    error_callback?: (error: unknown) => void;
  }) => GoogleTokenClient;
}

declare global {
  interface Window {
    google?: {
      accounts?: {
        oauth2?: GoogleOAuth2;
      };
    };
  }
}

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

interface GoogleDriveAdapterDeps {
  fetcher?: Fetcher;
  requestAccessToken?: (clientId: string) => Promise<string>;
}

interface GoogleDriveAdapterOptions {
  clientId?: string;
  deps?: GoogleDriveAdapterDeps;
}

interface GoogleDriveFile {
  id: string;
  name?: string;
  mimeType?: string;
  size?: string;
  webViewLink?: string;
}

interface GoogleDriveFileList {
  files: GoogleDriveFile[];
}

let identityScriptPromise: Promise<void> | null = null;

export function createGoogleDriveAdapter(
  options: GoogleDriveAdapterOptions = {},
): CloudDriveProviderAdapter {
  const clientId = options.clientId ?? import.meta.env.VITE_GOOGLE_CLIENT_ID;
  const fetcher = options.deps?.fetcher ?? fetch;
  const requestAccessToken =
    options.deps?.requestAccessToken ?? requestGoogleAccessToken;

  return {
    id: "google_drive",
    label: "Google Drive",
    available: typeof clientId === "string" && clientId.trim().length > 0,
    maxFileBytes: MAX_CLOUD_FILE_BYTES,
    upload: async (file: File) => {
      assertCloudFileSize(file.size);
      if (!clientId?.trim()) {
        throw new CloudDriveError(
          "missing_client_id",
          "Google Drive uploads need VITE_GOOGLE_CLIENT_ID.",
        );
      }
      let accessToken: string;
      try {
        accessToken = await requestAccessToken(clientId.trim());
      } catch (error) {
        if (error instanceof CloudDriveError) throw error;
        throw new CloudDriveError(
          "auth_failed",
          "Google authorization failed.",
        );
      }
      return uploadFileToGoogleDrive(file, accessToken, fetcher);
    },
  };
}

export function assertCloudFileSize(sizeBytes: number): void {
  if (sizeBytes > MAX_CLOUD_FILE_BYTES) {
    throw new CloudDriveError(
      "file_too_large",
      "This file is larger than the v1 cloud upload limit.",
    );
  }
}

export function buildGoogleDriveMultipartBody(
  metadata: Record<string, unknown>,
  file: File,
  boundary = `chronicle_${crypto.randomUUID()}`,
): { body: Blob; contentType: string } {
  const mimeType = file.type || DEFAULT_MIME_TYPE;
  const delimiter = `--${boundary}`;
  const closeDelimiter = `--${boundary}--`;
  const body = new Blob(
    [
      `${delimiter}\r\n`,
      "Content-Type: application/json; charset=UTF-8\r\n\r\n",
      JSON.stringify(metadata),
      "\r\n",
      `${delimiter}\r\n`,
      `Content-Type: ${mimeType}\r\n\r\n`,
      file,
      "\r\n",
      closeDelimiter,
      "\r\n",
    ],
    { type: `multipart/related; boundary=${boundary}` },
  );
  return {
    body,
    contentType: `multipart/related; boundary=${boundary}`,
  };
}

async function uploadFileToGoogleDrive(
  file: File,
  accessToken: string,
  fetcher: Fetcher,
): Promise<CloudAttachmentDraft> {
  const folderId = await ensureChronicleFolder(accessToken, fetcher);
  const fileResponse = await createGoogleDriveFile(
    file,
    folderId,
    accessToken,
    fetcher,
  );
  return {
    provider: "google_drive",
    providerFileId: fileResponse.id,
    name: fileResponse.name ?? file.name,
    mimeType: fileResponse.mimeType ?? (file.type || undefined),
    sizeBytes: file.size,
    webUrl:
      fileResponse.webViewLink ??
      `https://drive.google.com/file/d/${encodeURIComponent(fileResponse.id)}/view`,
  };
}

async function ensureChronicleFolder(
  accessToken: string,
  fetcher: Fetcher,
): Promise<string> {
  const searchUrl = new URL(`${DRIVE_API_BASE_URL}/files`);
  searchUrl.searchParams.set(
    "q",
    [
      "mimeType='application/vnd.google-apps.folder'",
      `name='${escapeDriveQueryValue(CHRONICLE_FOLDER_NAME)}'`,
      "trashed=false",
    ].join(" and "),
  );
  searchUrl.searchParams.set("spaces", "drive");
  searchUrl.searchParams.set("fields", "files(id,name)");
  searchUrl.searchParams.set("pageSize", "1");

  const list = await requestDriveJson<GoogleDriveFileList>(
    fetcher,
    searchUrl,
    { method: "GET" },
    accessToken,
    isGoogleDriveFileList,
  );
  const existingFolder = list.files[0];
  if (existingFolder) return existingFolder.id;

  const createUrl = new URL(`${DRIVE_API_BASE_URL}/files`);
  createUrl.searchParams.set("fields", "id,name");
  const folder = await requestDriveJson<GoogleDriveFile>(
    fetcher,
    createUrl,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: CHRONICLE_FOLDER_NAME,
        mimeType: "application/vnd.google-apps.folder",
        appProperties: { chronicle: "true" },
      }),
    },
    accessToken,
    isGoogleDriveFile,
  );
  return folder.id;
}

async function createGoogleDriveFile(
  file: File,
  folderId: string,
  accessToken: string,
  fetcher: Fetcher,
): Promise<GoogleDriveFile> {
  const uploadUrl = new URL(`${DRIVE_UPLOAD_BASE_URL}/files`);
  uploadUrl.searchParams.set("uploadType", "multipart");
  uploadUrl.searchParams.set("fields", "id,name,mimeType,size,webViewLink");
  const { body, contentType } = buildGoogleDriveMultipartBody(
    {
      name: file.name,
      mimeType: file.type || DEFAULT_MIME_TYPE,
      parents: [folderId],
      appProperties: { chronicle: "true" },
    },
    file,
  );
  return requestDriveJson<GoogleDriveFile>(
    fetcher,
    uploadUrl,
    {
      method: "POST",
      headers: { "Content-Type": contentType },
      body,
    },
    accessToken,
    isGoogleDriveFile,
  );
}

async function requestDriveJson<T>(
  fetcher: Fetcher,
  input: RequestInfo | URL,
  init: RequestInit,
  accessToken: string,
  guard: (value: unknown) => value is T,
): Promise<T> {
  let response: Response;
  try {
    response = await fetcher(input, {
      ...init,
      headers: {
        ...init.headers,
        Authorization: `Bearer ${accessToken}`,
      },
    });
  } catch {
    throw new CloudDriveError("upload_failed", "Google Drive request failed.");
  }
  if (!response.ok) {
    throw new CloudDriveError("upload_failed", "Google Drive rejected upload.");
  }
  const data = (await response.json().catch(() => null)) as unknown;
  if (!guard(data)) {
    throw new CloudDriveError(
      "upload_failed",
      "Google Drive returned an unexpected response.",
    );
  }
  return data;
}

async function requestGoogleAccessToken(clientId: string): Promise<string> {
  await loadGoogleIdentityScript();
  const oauth2 = window.google?.accounts?.oauth2;
  if (!oauth2) {
    throw new CloudDriveError(
      "auth_failed",
      "Google Identity Services did not load.",
    );
  }
  return new Promise((resolve, reject) => {
    const client = oauth2.initTokenClient({
      client_id: clientId,
      scope: GOOGLE_DRIVE_FILE_SCOPE,
      callback: (response) => {
        if (response.error || !response.access_token) {
          reject(
            new CloudDriveError(
              "auth_failed",
              response.error_description || "Google authorization failed.",
            ),
          );
          return;
        }
        resolve(response.access_token);
      },
      error_callback: () => {
        reject(
          new CloudDriveError("auth_failed", "Google authorization failed."),
        );
      },
    });
    client.requestAccessToken();
  });
}

function loadGoogleIdentityScript(): Promise<void> {
  if (window.google?.accounts?.oauth2) return Promise.resolve();
  if (identityScriptPromise) return identityScriptPromise;

  identityScriptPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = GOOGLE_IDENTITY_SCRIPT_URL;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => {
      identityScriptPromise = null;
      reject(
        new CloudDriveError(
          "auth_failed",
          "Google Identity Services did not load.",
        ),
      );
    };
    document.head.append(script);
  });
  return identityScriptPromise;
}

function escapeDriveQueryValue(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
}

function isGoogleDriveFile(value: unknown): value is GoogleDriveFile {
  if (!isRecord(value)) return false;
  return typeof value.id === "string" && value.id.length > 0;
}

function isGoogleDriveFileList(value: unknown): value is GoogleDriveFileList {
  if (!isRecord(value) || !Array.isArray(value.files)) return false;
  return value.files.every(isGoogleDriveFile);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
