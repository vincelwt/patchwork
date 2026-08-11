import { Stack } from "expo-router";

import { useLayout } from "@/lib/layout";
import { useTheme } from "@/lib/theme";

/// Every tab's root looks the same: a title and its own actions on the right.
/// Which workspace is on screen is the More tab's icon, not a control that
/// costs every tab a row of its header. A large title sits on the leading
/// edge, which only lines up while the content below it does too, so a big
/// screen centres both instead.
export function PrimaryStack({ title, detail }: { title: string; detail?: string }) {
  const theme = useTheme();
  const { wide } = useLayout();
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
        options={{ title, headerLargeTitle: !wide }}
      />
      {/* A detail screen leads with a header row or a bottom-anchored list, so it
          keeps an opaque bar rather than letting content slide under it. */}
      {detail ? (
        <Stack.Screen name={detail} options={{ headerLargeTitle: false, headerTransparent: false }} />
      ) : null}
    </Stack>
  );
}
