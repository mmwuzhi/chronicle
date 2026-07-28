export interface FingerprintableFile {
  name: string;
  size: number;
  type: string;
  lastModified: number;
  arrayBuffer: () => Promise<ArrayBuffer>;
}

// An operation UUID may be reused only for the same selected bytes. Metadata
// alone is not an identity: two different files can share name, size, MIME type,
// and lastModified, which would make a Drive retry attach the wrong object.
export async function fingerprintFile(
  file: FingerprintableFile,
): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest(
    "SHA-256",
    await file.arrayBuffer(),
  );
  const contentHash = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return JSON.stringify([
    file.name,
    file.size,
    file.type,
    file.lastModified,
    contentHash,
  ]);
}
