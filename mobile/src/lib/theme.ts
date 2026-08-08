import { useColorScheme } from "react-native";

const palettes = {
  light: {
    bg: "#ffffff",
    sidebar: "#f7f7f5",
    surface: "#f7f7f5",
    raised: "#ffffff",
    input: "#ffffff",
    line: "rgba(20, 20, 18, 0.11)",
    text: "#1b1b19",
    muted: "#62625d",
    faint: "#73736d",
    accent: "#3b6fe0",
    accentSoft: "#e9effd",
    onAccent: "#ffffff",
    positive: "#2c7d55",
    positiveSoft: "#e9f5ee",
    caution: "#8b5d0d",
    cautionSoft: "#fff5df",
    danger: "#b6382b",
    dangerSoft: "#fceceb",
    code: "#f0f0ed",
    backdrop: "rgba(20, 20, 18, 0.34)",
  },
  dark: {
    bg: "#1a1a1a",
    sidebar: "#212121",
    surface: "#262626",
    raised: "#2b2b2b",
    input: "#202020",
    line: "rgba(255, 255, 250, 0.11)",
    text: "#ececea",
    muted: "#aaa9a3",
    faint: "#a5a59f",
    accent: "#7aa6ff",
    accentSoft: "#26395f",
    onAccent: "#111827",
    positive: "#72ce97",
    positiveSoft: "#20382a",
    caution: "#e2b35d",
    cautionSoft: "#40341f",
    danger: "#f28a80",
    dangerSoft: "#472724",
    code: "#151515",
    backdrop: "rgba(0, 0, 0, 0.62)",
  },
};

export type Palette = (typeof palettes)["light"];

export function useTheme(): Palette {
  return palettes[useColorScheme() === "dark" ? "dark" : "light"];
}
