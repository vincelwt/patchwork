// The desktop palette, in the two shades a phone needs.

import { useColorScheme } from "react-native";

const palettes = {
  light: {
    bg: "#ffffff",
    surface: "#f7f7f5",
    line: "rgba(20, 20, 18, 0.09)",
    text: "#1b1b19",
    muted: "#6b6b65",
    faint: "#73736d",
    accent: "#3b6fe0",
    accentSoft: "rgba(59, 111, 224, 0.11)",
    caution: "#9a6b16",
    danger: "#bd3f31",
  },
  dark: {
    bg: "#1a1a1a",
    surface: "#262626",
    line: "rgba(255, 255, 250, 0.08)",
    text: "#ececea",
    muted: "#9a9a94",
    faint: "#a5a59f",
    accent: "#6a9bff",
    accentSoft: "rgba(106, 155, 255, 0.16)",
    caution: "#dbab52",
    danger: "#ef7f74",
  },
};

export type Palette = (typeof palettes)["light"];

export function useTheme(): Palette {
  return palettes[useColorScheme() === "dark" ? "dark" : "light"];
}
