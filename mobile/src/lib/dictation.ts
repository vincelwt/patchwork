import { useCallback, useRef, useState } from "react";
import { Platform } from "react-native";
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from "expo-speech-recognition";

export function useDictation(onText: (text: string) => void) {
  const [recording, setRecording] = useState(false);
  const [error, setError] = useState("");
  const base = useRef("");
  const latest = useRef(onText);
  latest.current = onText;

  useSpeechRecognitionEvent("start", () => setRecording(true));
  useSpeechRecognitionEvent("end", () => setRecording(false));
  useSpeechRecognitionEvent("result", ({ results }) => {
    const transcript = results[0]?.transcript.trim();
    if (!transcript) return;
    latest.current(`${base.current}${base.current.trim() ? " " : ""}${transcript}`);
  });
  useSpeechRecognitionEvent("error", (event) => {
    setRecording(false);
    if (event.error !== "no-speech" && event.error !== "aborted") {
      setError(event.message || "Dictation stopped.");
    }
  });

  const start = useCallback(async (value: string) => {
    if (Platform.OS !== "ios") return;
    setError("");
    const permission = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
    if (!permission.granted) {
      setError("Allow microphone and speech recognition access to dictate.");
      return;
    }
    base.current = value.trimEnd();
    const onDevice = ExpoSpeechRecognitionModule.supportsOnDeviceRecognition();
    ExpoSpeechRecognitionModule.start({
      lang: Intl.DateTimeFormat().resolvedOptions().locale || "en-US",
      interimResults: true,
      continuous: false,
      addsPunctuation: true,
      requiresOnDeviceRecognition: onDevice,
      contextualStrings: ["Patchwork", "pull request", "worktree", "automation"],
    });
  }, []);

  const stop = useCallback(() => {
    ExpoSpeechRecognitionModule.stop();
  }, []);

  return {
    supported: Platform.OS === "ios",
    recording,
    error,
    start,
    stop,
  };
}
