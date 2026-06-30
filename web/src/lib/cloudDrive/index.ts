import { createGoogleDriveAdapter, MAX_CLOUD_FILE_BYTES } from "./googleDrive";
import type { CloudDriveProviderAdapter, CloudDriveProviderId } from "./types";
import { CloudDriveError } from "./types";

function createUnsupportedAdapter(
  id: Exclude<CloudDriveProviderId, "google_drive">,
  label: string,
): CloudDriveProviderAdapter {
  return {
    id,
    label,
    available: false,
    maxFileBytes: MAX_CLOUD_FILE_BYTES,
    upload: async () => {
      throw new CloudDriveError(
        "unsupported_provider",
        `${label} uploads are not available yet.`,
      );
    },
  };
}

export const cloudDriveProviders: Record<
  CloudDriveProviderId,
  CloudDriveProviderAdapter
> = {
  google_drive: createGoogleDriveAdapter(),
  onedrive: createUnsupportedAdapter("onedrive", "OneDrive"),
  dropbox: createUnsupportedAdapter("dropbox", "Dropbox"),
};

export function getCloudDriveProvider(
  id: CloudDriveProviderId,
): CloudDriveProviderAdapter {
  return cloudDriveProviders[id];
}

export type {
  CloudAttachmentDraft,
  CloudDriveErrorCode,
  CloudDriveProviderAdapter,
  CloudDriveProviderId,
} from "./types";
export { CloudDriveError, isCloudDriveError } from "./types";
export { MAX_CLOUD_FILE_BYTES };
