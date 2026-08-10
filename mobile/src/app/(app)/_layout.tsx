import { Redirect, Stack } from "expo-router";
import { View } from "react-native";

import { ConnectionBar } from "@/components/ui";
import { usePairedSession } from "@/lib/session";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AppLayout() {
  const { session } = usePairedSession();
  const workspace = useWorkspace();
  const theme = useTheme();

  if (session === null) return <Redirect href="/" />;

  return (
    <View style={{ flex: 1, backgroundColor: theme.bg }}>
      <Stack
        screenOptions={{
          animation: "default",
          animationTypeForReplace: "pop",
          contentStyle: { backgroundColor: theme.bg },
          gestureEnabled: true,
          headerBackButtonDisplayMode: "minimal",
          headerShadowVisible: false,
          headerTransparent: true,
        }}
      >
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
      </Stack>
      <ConnectionBar connection={workspace.connection} error={workspace.error} />
    </View>
  );
}
