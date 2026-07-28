import { describe, expect, it } from "vitest";
import {
  fingerprintFile,
  type FingerprintableFile,
} from "@/utils/file-fingerprint";

function file(bytes: number[]): FingerprintableFile {
  return {
    name: "same.bin",
    size: bytes.length,
    type: "application/octet-stream",
    lastModified: 1_700_000_000_000,
    arrayBuffer: async () => Uint8Array.from(bytes).buffer,
  };
}

describe("fingerprintFile", () => {
  it("distinguishes different bytes with identical file metadata", async () => {
    await expect(fingerprintFile(file([1, 2, 3]))).resolves.not.toBe(
      await fingerprintFile(file([3, 2, 1])),
    );
  });

  it("reuses the identity for a genuine retry of the same file", async () => {
    await expect(fingerprintFile(file([1, 2, 3]))).resolves.toBe(
      await fingerprintFile(file([1, 2, 3])),
    );
  });
});
