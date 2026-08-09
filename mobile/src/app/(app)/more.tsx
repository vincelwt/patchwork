import { Pressable, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import { Icon, PageHeader, Screen } from "@/components/ui";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

const items = [
  { href: "/(app)/search", label: "Search", detail: "Find messages and tasks", icon: { ios: "magnifyingglass", android: "search", web: "search" } },
  { href: "/(app)/automations", label: "Automations", detail: "Schedules, triggers, and run history", icon: { ios: "bolt.circle.fill", android: "bolt", web: "bolt" } },
  { href: "/(app)/members", label: "Members", detail: "People, agents, DMs, and invitations", icon: { ios: "person.3.fill", android: "group", web: "group" } },
  { href: "/(app)/settings", label: "Settings", detail: "This device and connection", icon: { ios: "gearshape.fill", android: "settings", web: "settings" } },
] as const;

export default function MoreScreen() {
  const theme = useTheme();
  const router = useRouter();
  const data = useWorkspace().bootstrap;
  return (
    <Screen>
      <PageHeader title="More" subtitle={data?.workspace.name} />
      <View style={[styles.list, { backgroundColor: theme.raised, borderColor: theme.line }]}>
        {items.map((item) => (
          <Pressable
            key={item.href}
            onPress={() => router.push(item.href)}
            style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
          >
            <View style={[styles.icon, { backgroundColor: theme.accentSoft }]}>
              <Icon name={item.icon} color={theme.accent} size={20} />
            </View>
            <View style={styles.main}>
              <Text style={[styles.title, { color: theme.text }]}>{item.label}</Text>
              <Text style={[styles.detail, { color: theme.muted }]}>{item.detail}</Text>
            </View>
            <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={16} />
          </Pressable>
        ))}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { margin: 16, borderWidth: StyleSheet.hairlineWidth, borderRadius: 14, overflow: "hidden" },
  row: { minHeight: 72, flexDirection: "row", alignItems: "center", gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 12, paddingVertical: 10 },
  icon: { width: 36, height: 36, borderRadius: 10, alignItems: "center", justifyContent: "center" },
  main: { flex: 1 },
  title: { fontSize: 16, fontWeight: "700" },
  detail: { fontSize: 13, marginTop: 3 },
});
