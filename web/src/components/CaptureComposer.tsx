import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  getCloudDriveProvider,
  isCloudDriveError,
  type CloudAttachmentDraft,
} from "../lib/cloudDrive";
import { apiClient } from "../lib/axios";
import { Composer } from "./Composer";

interface UploadResult {
  id: string;
}

const MAX_RECORDING_SECONDS = 5 * 60;

// Mirrors maxUploadSize in api/internal/upload/handler.go — the two must
// change together. At the cap the attach flow falls back to the cloud-drive
// route instead of failing the direct upload.
const DIRECT_UPLOAD_MAX_BYTES = 20 * 1024 * 1024;

interface CaptureComposerProps {
  creating: boolean;
  onCreate: (text: string, onSuccess: () => void) => void;
  onCreateAttachmentCapture: (text: string) => Promise<string>;
  onAttachCloudFile: (
    captureId: string,
    attachment: CloudAttachmentDraft,
  ) => Promise<void>;
  onUploaded: () => void;
}

export function CaptureComposer({
  creating,
  onCreate,
  onCreateAttachmentCapture,
  onAttachCloudFile,
  onUploaded,
}: CaptureComposerProps): React.JSX.Element {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const [text, setText] = useState("");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const [recordingSeconds, setRecordingSeconds] = useState(0);
  const attachInputRef = useRef<HTMLInputElement>(null);
  // Latest-value ref: upload() and the recorder's onstop run from closures
  // that outlive the render which created them, so they read the draft here.
  const textRef = useRef(text);
  useEffect(() => {
    textRef.current = text;
  }, [text]);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const audioChunksRef = useRef<Blob[]>([]);
  const recordingStartedAtRef = useRef(0);
  const recordingTimerRef = useRef<number | null>(null);
  const recordingTimeoutRef = useRef<number | null>(null);
  const cancelRecordingRef = useRef(false);

  const clearRecordingTimers = useCallback(() => {
    if (recordingTimerRef.current != null) {
      window.clearInterval(recordingTimerRef.current);
      recordingTimerRef.current = null;
    }
    if (recordingTimeoutRef.current != null) {
      window.clearTimeout(recordingTimeoutRef.current);
      recordingTimeoutRef.current = null;
    }
  }, []);

  useEffect(
    () => () => {
      cancelRecordingRef.current = true;
      clearRecordingTimers();
      const recorder = mediaRecorderRef.current;
      if (recorder?.state === "recording") recorder.stop();
      recorder?.stream.getTracks().forEach((track) => track.stop());
    },
    [clearRecordingTimers],
  );

  // A media capture absorbs the composer draft as its text; clear the box
  // only if the draft is still what we sent, so typing during a slow upload
  // is never destroyed.
  const consumeDraft = (sent: string) => {
    if (sent) setText((current) => (current.trim() === sent ? "" : current));
  };

  const upload = async (
    file: File | Blob,
    filename?: string,
    durationSec?: number,
  ) => {
    setUploadError(null);
    setUploading(true);
    const draft = textRef.current.trim();
    try {
      const form = new FormData();
      form.append(
        "file",
        file,
        filename ?? (file instanceof File ? file.name : "recording.webm"),
      );
      form.append("createCapture", "true");
      if (draft) form.append("text", draft);
      if (durationSec != null) form.append("durationSec", String(durationSec));
      await apiClient.post<UploadResult>("/captures/upload", form);
      consumeDraft(draft);
      onUploaded();
    } catch {
      setUploadError(t("uploadFailed"));
      window.setTimeout(() => setUploadError(null), 3000);
    } finally {
      setUploading(false);
    }
  };

  const uploadToCloud = async (file: File) => {
    setUploadError(null);
    setUploading(true);
    const draft = textRef.current.trim();
    try {
      const adapter = getCloudDriveProvider("google_drive");
      const attachment = await adapter.upload(file);
      const captureId = await onCreateAttachmentCapture(draft || file.name);
      await onAttachCloudFile(captureId, attachment);
      consumeDraft(draft);
      onUploaded();
    } catch (error) {
      setUploadError(t(cloudUploadErrorKey(error)));
      window.setTimeout(() => setUploadError(null), 4000);
    } finally {
      setUploading(false);
    }
  };

  // One attach entry, no destination choice: media the server can transcribe
  // (and fit under the direct-upload cap) stays on Chronicle's R2 and enters
  // the OCR/Whisper pipeline; everything else goes to the user's cloud drive
  // as an external reference.
  const handleAttachPick = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    const transcribable =
      file.type.startsWith("image/") || file.type.startsWith("audio/");
    if (transcribable && file.size <= DIRECT_UPLOAD_MAX_BYTES) {
      void upload(file);
    } else {
      void uploadToCloud(file);
    }
  };

  const handleAudioToggle = async () => {
    if (recording) {
      if (mediaRecorderRef.current?.state === "recording") {
        mediaRecorderRef.current.stop();
      }
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      cancelRecordingRef.current = false;
      audioChunksRef.current = [];
      recorder.ondataavailable = (event) =>
        audioChunksRef.current.push(event.data);
      recorder.onstop = () => {
        clearRecordingTimers();
        stream.getTracks().forEach((track) => track.stop());
        setRecording(false);
        mediaRecorderRef.current = null;
        const durationSec = Math.max(
          1,
          Math.min(
            MAX_RECORDING_SECONDS,
            Math.ceil((Date.now() - recordingStartedAtRef.current) / 1000),
          ),
        );
        setRecordingSeconds(0);
        if (cancelRecordingRef.current) return;
        const blob = new Blob(audioChunksRef.current, { type: "audio/webm" });
        void upload(blob, "recording.webm", durationSec);
      };
      recorder.start();
      mediaRecorderRef.current = recorder;
      recordingStartedAtRef.current = Date.now();
      setRecording(true);
      setRecordingSeconds(0);
      recordingTimerRef.current = window.setInterval(() => {
        setRecordingSeconds(
          Math.min(
            MAX_RECORDING_SECONDS,
            Math.floor((Date.now() - recordingStartedAtRef.current) / 1000),
          ),
        );
      }, 1000);
      recordingTimeoutRef.current = window.setTimeout(() => {
        if (recorder.state === "recording") recorder.stop();
      }, MAX_RECORDING_SECONDS * 1000);
    } catch {
      setUploadError(t("uploadFailed"));
      window.setTimeout(() => setUploadError(null), 3000);
    }
  };

  const handlePolish = async (value: string) => {
    const response = await apiClient.post<{ polished: string }>("/ai/polish", {
      text: value.trim(),
    });
    return response.data.polished;
  };

  return (
    <Composer
      value={text}
      onChange={setText}
      onSubmit={(value) => {
        const trimmed = value.trim();
        if (!trimmed) return;
        onCreate(trimmed, () => setText(""));
      }}
      placeholder={t("placeholder")}
      submitLabel={tc("actions.save")}
      submitDisabled={creating}
      tagSuggestions={[{ tag: "#todo", hint: t("tagMenu.todoHint") }]}
      onPolish={handlePolish}
      onAttach={() => attachInputRef.current?.click()}
      onRecord={() => void handleAudioToggle()}
      attachLabel={t("attach")}
      recordLabel={
        recording
          ? `${t("stopRecording")} ${Math.floor(recordingSeconds / 60)}:${String(recordingSeconds % 60).padStart(2, "0")} / 5:00`
          : t("record")
      }
      recording={recording}
      busy={uploading || recording}
      busyLabel={recording ? t("recording") : t("uploading")}
      error={uploadError}
      attachmentInput={
        <input
          ref={attachInputRef}
          type="file"
          className="hidden"
          onChange={handleAttachPick}
        />
      }
    />
  );
}

function cloudUploadErrorKey(error: unknown): string {
  if (!isCloudDriveError(error)) return "cloudFile.uploadFailed";
  switch (error.code) {
    case "missing_client_id":
      return "cloudFile.missingClientId";
    case "file_too_large":
      return "cloudFile.tooLarge";
    case "auth_failed":
      return "cloudFile.authFailed";
    case "upload_failed":
    case "unsupported_provider":
      return "cloudFile.uploadFailed";
  }
}
