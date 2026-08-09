import { useColorScheme } from "react-native";

const palettes = {
  light: {
    bg: "#f2f2f7",
    sidebar: "#f7f7fa",
    surface: "#ffffff",
    raised: "#ffffff",
    input: "#ffffff",
    line: "rgba(60, 60, 67, 0.18)",
    text: "#161618",
    muted: "#636366",
    faint: "#8e8e93",
    accent: "#3478f6",
    accentSoft: "#e8f0ff",
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
    bg: "#000000",
    sidebar: "#161618",
    surface: "#1c1c1e",
    raised: "#1c1c1e",
    input: "#2c2c2e",
    line: "rgba(84, 84, 88, 0.62)",
    text: "#f2f2f7",
    muted: "#aeaeb2",
    faint: "#8e8e93",
    accent: "#5e9bff",
    accentSoft: "#1d3155",
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
