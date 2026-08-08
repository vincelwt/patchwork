import { Pressable, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import { PageHeader, Screen } from "@/components/ui";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

const items = [
  { href: "/(app)/search", label: "Search", detail: "Find messages and tasks" },
  { href: "/(app)/automations", label: "Automations", detail: "Schedules, triggers, and run history" },
  { href: "/(app)/members", label: "Members", detail: "People, agents, DMs, and invitations" },
  { href: "/(app)/settings", label: "Settings", detail: "This device and connection" },
] as const;

export default function MoreScreen() {
  const theme = useTheme();
  const router = useRouter();
  const data = useWorkspace().bootstrap;
  return (
    <Screen>
      <PageHeader title="More" subtitle={data?.workspace.name} />
      <View style={styles.list}>
        {items.map((item) => (
          <Pressable
            key={item.href}
            onPress={() => router.push(item.href)}
            style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
          >
            <View style={styles.main}>
              <Text style={[styles.title, { color: theme.text }]}>{item.label}</Text>
              <Text style={[styles.detail, { color: theme.muted }]}>{item.detail}</Text>
            </View>
            <Text style={{ color: theme.faint, fontSize: 24 }}>›</Text>
          </Pressable>
        ))}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { paddingHorizontal: 16, paddingTop: 8 },
  row: { minHeight: 70, flexDirection: "row", alignItems: "center", borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 10 },
  main: { flex: 1 },
  title: { fontSize: 16, fontWeight: "700" },
  detail: { fontSize: 13, marginTop: 3 },
});
