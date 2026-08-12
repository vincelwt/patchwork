import { useEffect, useState } from "react";
import { Keyboard, Platform } from "react-native";

import { keyboardInset } from "@client/keyboard";

/// Android's window is edge to edge from Android 15 on and no longer resizes
/// for the keyboard, so `KeyboardAvoidingView` measures no overlap there and
/// leaves a composer sitting underneath it. Measuring the keyboard itself works
/// the same on both platforms.
export function useKeyboardInset(applied = 0): number {
  const [keyboard, setKeyboard] = useState(0);

  useEffect(() => {
    const ios = Platform.OS === "ios";
    // iOS animates alongside `will`; Android only ever reports `did`.
    const shown = Keyboard.addListener(ios ? "keyboardWillShow" : "keyboardDidShow", (event) =>
      setKeyboard(event.endCoordinates.height),
    );
    const hidden = Keyboard.addListener(ios ? "keyboardWillHide" : "keyboardDidHide", () => setKeyboard(0));
    return () => {
      shown.remove();
      hidden.remove();
    };
  }, []);

  return keyboardInset(keyboard, applied, Platform.OS === "ios");
}
