import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useGetCapture, type CaptureBody } from "@/api";
import { patchCaptureInPages } from "@/utils/capture-cache";

const POLL_INTERVAL_MS = 3000;

// Polls a single in-flight transcription (one-row GET every 3s) and patches the
// capture into the cached page lists when it moves — replacing the old
// list-level refetchInterval that re-fetched every loaded page while any
// transcription was pending.
export function useTranscriptionPoll(capture: CaptureBody): void {
  const queryClient = useQueryClient();
  const polling =
    (capture.mediaType === "audio" || capture.mediaType === "image") &&
    ["pending", "processing"].includes(capture.transcriptionStatus);
  const { data: fresh } = useGetCapture(capture.id, {
    query: {
      enabled: polling,
      refetchInterval: polling ? POLL_INTERVAL_MS : false,
    },
  });

  useEffect(() => {
    if (!polling || !fresh) return;
    if (
      fresh.transcriptionStatus !== capture.transcriptionStatus ||
      fresh.transcript !== capture.transcript
    ) {
      patchCaptureInPages(queryClient, fresh);
    }
  }, [polling, fresh, capture, queryClient]);
}
