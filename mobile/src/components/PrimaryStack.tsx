import { Stack } from "expo-router";

import { useTheme } from "@/lib/theme";
import { WorkspaceButton } from "./WorkspaceSwitcher";

/// Every tab's root looks the same: a large title, the workspace it belongs to
/// on the left, and its own actions on the right.
export function PrimaryStack({ title, detail }: { title: string; detail?: string }) {
  const theme = useTheme();
  return (
    <Stack
      screenOptions={{
        animation: "default",
        contentStyle: { backgroundColor: theme.surface },
        gestureEnabled: true,
        headerBackButtonDisplayMode: "minimal",
        headerLargeTitleShadowVisible: false,
        headerShadowVisible: false,
        headerTransparent: true,
      }}
    >
      <Stack.Screen
        name="index"
        options={{ title, headerLargeTitle: true, headerLeft: () => <WorkspaceButton /> }}
      />
      {/* A detail screen leads with a header row or a bottom-anchored list, so it
          keeps an opaque bar rather than letting content slide under it. */}
      {detail ? (
        <Stack.Screen name={detail} options={{ headerLargeTitle: false, headerTransparent: false }} />
      ) : null}
    </Stack>
  );
}
