import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import type { Automation } from "@client/types";
import { AutomationEditor } from "@/components/AutomationEditor";
import { Avatar, Badge, Button, Empty, PageHeader, Sheet } from "@/components/ui";
import { relative, triggerLabel } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AutomationsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const [creating, setCreating] = useState(false);
  const automations = workspace.bootstrap?.automations ?? [];
  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader title="Automations" subtitle={`${automations.length} workflows`} action={<Button label="New" compact onPress={() => setCreating(true)} />} />
      <ScrollView contentContainerStyle={styles.scroll}>
        {automations.map((automation) => <AutomationRow key={automation.id} automation={automation} />)}
        {!automations.length ? <Empty title="No automations yet" detail="Choose what fires, which agent acts, and where the result lands." /> : null}
      </ScrollView>
      <Sheet visible={creating} title="New automation" onClose={() => setCreating(false)}>
        <AutomationEditor
          onSaved={(automation) => {
            setCreating(false);
            router.push({ pathname: "/(app)/automations/[automationId]", params: { automationId: automation.id } });
          }}
        />
      </Sheet>
    </View>
  );

  function AutomationRow({ automation }: { automation: Automation }) {
    const agent = workspace.bootstrap?.members.find((member) => member.id === automation.agent_id);
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
          <Text style={[styles.time, { color: theme.faint }]}>{automation.next_run_at ? `Next ${relative(automation.next_run_at)}` : automation.last_run_at ? `Last ${relative(automation.last_run_at)}` : "Never run"}</Text>
        </View>
        {automation.failure_count ? <Badge tone="danger">{automation.failure_count} failed</Badge> : null}
        <Button label="Run" compact tone="quiet" onPress={() => void store.mutate((api) => api.runAutomation(automation.id))} />
      </Pressable>
    );
  }
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { paddingHorizontal: 14, paddingBottom: 30 },
  row: { minHeight: 82, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 11 },
  main: { flex: 1, minWidth: 0, gap: 3 },
  head: { flexDirection: "row", alignItems: "center", gap: 6 },
  name: { flex: 1, fontSize: 16, fontWeight: "700" },
  time: { fontSize: 11 },
});
