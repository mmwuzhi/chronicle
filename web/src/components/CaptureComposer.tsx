import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { apiClient } from "../lib/axios";
import { Composer } from "./Composer";

interface UploadResult {
  id: string;
}

const MAX_RECORDING_SECONDS = 5 * 60;

interface CaptureComposerProps {
  creating: boolean;
  onCreate: (text: string, onSuccess: () => void) => void;
  onUploaded: () => void;
}

export function CaptureComposer({
  creating,
  onCreate,
  onUploaded,
}: CaptureComposerProps): React.JSX.Element {
  const { t } = useTranslation("captures");
  const { t: tc } = useTranslation("common");
  const [text, setText] = useState("");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState(false);
  const [recording, setRecording] = useState(false);
  const [recordingSeconds, setRecordingSeconds] = useState(0);
  const imageInputRef = useRef<HTMLInputElement>(null);
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

  const upload = async (
    file: File | Blob,
    filename?: string,
    durationSec?: number,
  ) => {
    setUploadError(false);
    setUploading(true);
    try {
      const form = new FormData();
      form.append(
        "file",
        file,
        filename ?? (file instanceof File ? file.name : "recording.webm"),
      );
      form.append("createCapture", "true");
      if (durationSec != null) form.append("durationSec", String(durationSec));
      await apiClient.post<UploadResult>("/captures/upload", form);
      onUploaded();
    } catch {
      setUploadError(true);
      window.setTimeout(() => setUploadError(false), 3000);
    } finally {
      setUploading(false);
    }
  };

  const handleImageUpload = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) void upload(file);
    event.target.value = "";
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
      setUploadError(true);
      window.setTimeout(() => setUploadError(false), 3000);
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
      onPolish={handlePolish}
      onAttach={() => imageInputRef.current?.click()}
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
      error={uploadError ? t("uploadFailed") : null}
      attachmentInput={
        <input
          ref={imageInputRef}
          type="file"
          accept="image/*"
          className="ch-hidden-input"
          onChange={handleImageUpload}
        />
      }
    />
  );
}
