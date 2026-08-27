import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import type { Automation } from "@client/types";
import { Avatar, Badge, Button, Empty, Grouped } from "@/components/ui";
import { relative, triggerLabel, watchHealth } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AutomationsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const automations = workspace.bootstrap?.automations ?? [];
  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen options={{ title: "Automations" }} />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
       <Grouped>
        {automations.map((automation) => <AutomationRow key={automation.id} automation={automation} />)}
        {/* Automations are wired up at a keyboard; the phone runs and watches
            them. */}
        {!automations.length ? <Empty title="No automations yet" detail="Set one up in Patchwork Desktop." /> : null}
       </Grouped>
      </ScrollView>
    </View>
  );

  function AutomationRow({ automation }: { automation: Automation }) {
    const agent = workspace.bootstrap?.members.find((member) => member.id === automation.agent_id);
    const health =
      automation.trigger.type === "watch" || automation.blocked_reason || automation.overdue_since
        ? watchHealth(automation)
        : undefined;
    return (
      <Pressable
        onPress={() => router.push({ pathname: "/(app)/automations/[automationId]", params: { automationId: automation.id } })}
        style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
      >
        <Avatar member={agent} />
        <View style={styles.main}>
          <View style={styles.head}>
            <Text numberOfLines={1} style={[styles.name, { color: theme.text }]}>{automation.name}</Text>
            <Badge tone={automation.enabled ? "positive" : "neutral"}>{automation.enabled ? "on" : "paused"}</Badge>
          </View>
          <Text numberOfLines={1} style={{ color: theme.muted }}>{triggerLabel(automation.trigger)} · {agent?.display_name ?? "no agent"}</Text>
          <Text style={[styles.time, { color: health?.tone === "danger" ? theme.danger : theme.faint }]}>
            {health
              ? health.text
              : automation.next_run_at ? `Next ${relative(automation.next_run_at)}` : automation.last_run_at ? `Last ${relative(automation.last_run_at)}` : "Never run"}
          </Text>
        </View>
        {health ? (
          health.tone === "danger" ? <Badge tone="danger">failing</Badge> : null
        ) : automation.failure_count ? <Badge tone="danger">{automation.failure_count} failed</Badge> : null}
        <Button label="Run" compact tone="quiet" disabled={!automation.enabled} onPress={() => void store.mutate((api) => api.runAutomation(automation.id))} />
      </Pressable>
    );
  }
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { paddingBottom: 30 },
  row: { minHeight: 82, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 11 },
  main: { flex: 1, minWidth: 0, gap: 3 },
  head: { flexDirection: "row", alignItems: "center", gap: 6 },
  name: { flex: 1, fontSize: 16, fontWeight: "700" },
  time: { fontSize: 11 },
});
