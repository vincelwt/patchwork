import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useColorScheme } from "react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";

import { usePairedSession } from "@/lib/session";
import { WorkspaceProvider } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function RootLayout() {
  const scheme = useColorScheme();
  const theme = useTheme();
  const { session, workspaces } = usePairedSession();
  const base = scheme === "dark" ? DarkTheme : DefaultTheme;

  return (
    <SafeAreaProvider>
      <ThemeProvider
        value={{
          ...base,
          colors: {
            ...base.colors,
            background: theme.bg,
            card: theme.surface,
            text: theme.text,
            border: theme.line,
            primary: theme.accent,
          },
        }}
      >
        <WorkspaceProvider session={session} workspaces={workspaces}>
          <Stack screenOptions={{ headerShown: false, animation: "simple_push" }} />
        </WorkspaceProvider>
        <StatusBar style="auto" />
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
