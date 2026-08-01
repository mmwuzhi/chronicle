import type { CaptureBody } from "@/api";

type CaptureTextFields = Pick<CaptureBody, "rawText" | "transcript">;

export function captureText(capture: CaptureTextFields): string {
  return capture.rawText || capture.transcript || "";
}

export function truncateCaptureText(
  capture: CaptureTextFields,
  maxCharacters: number,
): string {
  const text = captureText(capture).trim();
  if (text.length <= maxCharacters) return text;
  return `${text.slice(0, maxCharacters).trimEnd()}…`;
}
