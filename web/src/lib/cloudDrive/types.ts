export type CloudDriveProviderId = "google_drive" | "onedrive" | "dropbox";

export interface CloudAttachmentDraft {
  provider: CloudDriveProviderId;
  providerFileId: string;
  name: string;
  mimeType?: string;
  sizeBytes?: number;
  webUrl: string;
}

export interface CloudDriveProviderAdapter {
  id: CloudDriveProviderId;
  label: string;
  available: boolean;
  maxFileBytes: number;
  upload: (file: File, operationId: string) => Promise<CloudAttachmentDraft>;
}

export type CloudDriveErrorCode =
  | "missing_client_id"
  | "file_too_large"
  | "auth_failed"
  | "upload_failed"
  | "unsupported_provider";

export class CloudDriveError extends Error {
  readonly code: CloudDriveErrorCode;

  constructor(code: CloudDriveErrorCode, message: string) {
    super(message);
    this.name = "CloudDriveError";
    this.code = code;
  }
}

export function isCloudDriveError(error: unknown): error is CloudDriveError {
  return error instanceof CloudDriveError;
}
