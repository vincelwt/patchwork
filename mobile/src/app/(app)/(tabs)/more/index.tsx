import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import { Grouped, Icon, Screen } from "@/components/ui";
import { useTheme } from "@/lib/theme";

const items = [
  { href: "/(app)/agents", label: "Agents", detail: "Agent teammates and runtimes", icon: { ios: "person.2", android: "support_agent", web: "support_agent" } },
  { href: "/(app)/automations", label: "Automations", detail: "Schedules, triggers, and run history", icon: { ios: "bolt.circle.fill", android: "bolt", web: "bolt" } },
  { href: "/(app)/members", label: "Members", detail: "People, agents, DMs, and invitations", icon: { ios: "person.3.fill", android: "group", web: "group" } },
  { href: "/(app)/settings", label: "Settings", detail: "This device and connection", icon: { ios: "gearshape.fill", android: "settings", web: "settings" } },
] as const;

export default function MoreScreen() {
  const theme = useTheme();
  const router = useRouter();
  return (
    <Screen style={{ backgroundColor: theme.surface }}>
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.list}>
       <Grouped>
        {items.map((item) => (
          <Pressable
            key={item.href}
            onPress={() => router.push(item.href)}
            style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
          >
            <View style={styles.icon}>
              <Icon name={item.icon} color={theme.accent} size={20} />
            </View>
            <View style={styles.main}>
              <Text style={[styles.title, { color: theme.text }]}>{item.label}</Text>
              <Text style={[styles.detail, { color: theme.muted }]}>{item.detail}</Text>
            </View>
            <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={16} />
          </Pressable>
        ))}
       </Grouped>
      </ScrollView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { paddingBottom: 24 },
  row: { minHeight: 72, flexDirection: "row", alignItems: "center", gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 10 },
  icon: { width: 30, alignItems: "center", justifyContent: "center" },
  main: { flex: 1 },
  title: { fontSize: 16, fontWeight: "700" },
  detail: { fontSize: 13, marginTop: 3 },
});
