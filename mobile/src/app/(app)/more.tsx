import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import { WorkspaceMark, WorkspaceSheet } from "@/components/WorkspaceSwitcher";
import { Grouped, Icon, Screen } from "@/components/ui";
import { workspaceLabel } from "@/lib/paired";
import { usePairedSession } from "@/lib/session";
import { useWorkspace } from "@/lib/store";
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
  const { session, workspaces } = usePairedSession();
  const live = useWorkspace().bootstrap?.workspace.name;
  const [switching, setSwitching] = useState(false);
  const named = session ? { ...session, name: live || session.name } : null;

  return (
    <Screen style={{ backgroundColor: theme.surface }}>
      <Stack.Screen options={{ title: "More" }} />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.list}>
       <Grouped>
        {/* The workspace leads this screen, so switching costs one tap from
            Home instead of a control on every screen. */}
        {named ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={`Workspace ${workspaceLabel(named)}. Switch workspace`}
            onPress={() => setSwitching(true)}
            style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
          >
            <WorkspaceMark session={named} size={30} />
            <View style={styles.main}>
              <Text numberOfLines={1} style={[styles.title, { color: theme.text }]}>{workspaceLabel(named)}</Text>
              <Text numberOfLines={1} style={[styles.detail, { color: theme.muted }]}>
                {workspaces.length > 1 ? `Switch between ${workspaces.length} workspaces` : "Pair another workspace"}
              </Text>
            </View>
            <Icon name={{ ios: "chevron.up.chevron.down", android: "unfold_more", web: "unfold_more" }} color={theme.faint} size={14} />
          </Pressable>
        ) : null}
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
      {named ? (
        <WorkspaceSheet visible={switching} onClose={() => setSwitching(false)} workspaces={workspaces} active={named} />
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: { paddingBottom: 24 },
  row: { minHeight: 58, flexDirection: "row", alignItems: "center", gap: 12, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 8 },
  icon: { width: 30, alignItems: "center", justifyContent: "center" },
  main: { flex: 1, minWidth: 0 },
  title: { fontSize: 16, fontWeight: "600" },
  detail: { fontSize: 13, marginTop: 1 },
});
