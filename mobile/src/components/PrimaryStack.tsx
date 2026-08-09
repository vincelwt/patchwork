import { Stack } from "expo-router";

import { useTheme } from "@/lib/theme";

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
      }}
    >
      <Stack.Screen name="index" options={{ title, headerLargeTitle: true }} />
      {detail ? <Stack.Screen name={detail} options={{ headerLargeTitle: false }} /> : null}
    </Stack>
  );
}
