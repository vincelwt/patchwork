import { useEffect, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useLocalSearchParams, useRouter } from "expo-router";

import type { AutomationDebug } from "@client/types";
import { AutomationEditor } from "@/components/AutomationEditor";
import { Badge, Button, Card, Empty, ErrorNotice, Measured, Sheet } from "@/components/ui";
import { relative, runStatusLabel, triggerLabel } from "@/lib/format";
import { usePairedSession } from "@/lib/session";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AutomationScreen() {
  const { automationId } = useLocalSearchParams<{ automationId: string }>();
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const { session } = usePairedSession();
  const automation = workspace.bootstrap?.automations.find((item) => item.id === automationId);
  const [debug, setDebug] = useState<AutomationDebug>();
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");

  const load = async () => {
    try {
      await store.mutate((api) => api.automationDebug(automationId), false, setDebug);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };
  useEffect(() => {
    void load();
  }, [automationId]);

  if (!automation) {
    return (
      <View style={styles.fill}>
        <Stack.Screen options={{ title: "Automation" }} />
        <Empty title="Automation unavailable" />
      </View>
    );
  }
  const agent = workspace.bootstrap?.members.find((member) => member.id === automation.agent_id);

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen
        options={{
          title: automation.name,
          headerRight: () => <Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} />,
        }}
      />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
       <Measured style={styles.measured}>
        <Card style={styles.card}>
          <View style={styles.titleRow}>
            <View style={styles.grow}>
              <Text style={[styles.name, { color: theme.text }]}>{automation.name}</Text>
              {automation.description ? <Text style={{ color: theme.muted, lineHeight: 20 }}>{automation.description}</Text> : null}
            </View>
            <Badge tone={automation.enabled ? "positive" : "neutral"}>{automation.enabled ? "on" : "paused"}</Badge>
          </View>
          <View style={styles.meta}>
            <Badge>{triggerLabel(automation.trigger)}</Badge>
            <Badge>{agent?.display_name ?? "no agent"}</Badge>
            <Badge>{automation.action.replaceAll("_", " ")}</Badge>
          </View>
          <View style={styles.actions}>
            <Button label="Run now" compact onPress={async () => { await store.mutate((api) => api.runAutomation(automation.id), true, (run) => { if (run.run_id) router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.run_id } }); void load(); }); }} />
            <Button
              label={automation.enabled ? "Pause" : "Resume"}
              compact
              tone="secondary"
              onPress={() => void store.mutate((api) => api.updateAutomation(automation.id, { ...automation, enabled: !automation.enabled }))}
            />
            <Button label="Delete" compact tone="danger" onPress={() => setDeleting(true)} />
          </View>
        </Card>
        <Text style={[styles.section, { color: theme.faint }]}>Instructions</Text>
        <Card style={styles.instructions}>
          <Text selectable style={{ color: automation.instructions ? theme.text : theme.faint, lineHeight: 21 }}>
            {automation.instructions || "No instructions. The agent receives only the trigger and context."}
          </Text>
        </Card>
        {automation.trigger.type === "webhook" && session ? (
          <Card style={styles.instructions}>
            <Text style={{ color: theme.text, fontWeight: "700" }}>Webhook</Text>
            <Text selectable style={{ color: theme.accent }}>
              POST {session.baseUrl}/api/webhooks/{automation.trigger.token}
            </Text>
          </Card>
        ) : null}
        {automation.trigger.type === "watch" ? (
          <Card style={styles.instructions}>
            <Text style={{ color: theme.text, fontWeight: "700" }}>Command</Text>
            <Text selectable style={{ color: theme.muted, fontFamily: "monospace" }}>{automation.trigger.command}</Text>
          </Card>
        ) : null}
        <Text style={[styles.section, { color: theme.faint }]}>Runs</Text>
        <Card>
          {debug?.runs.map((run) => (
            <Pressable
              key={run.id}
              onPress={() => run.run_id ? router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.run_id } }) : run.task_id ? router.push({ pathname: "/tasks/[taskId]", params: { taskId: run.task_id } }) : undefined}
              style={[styles.runRow, { borderBottomColor: theme.line }]}
            >
              <View style={styles.grow}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{run.trigger_summary}</Text>
                <Text style={{ color: theme.muted }}>{relative(run.created_at)}{run.error ? ` · ${run.error}` : ""}</Text>
              </View>
              <Badge tone={run.status === "failed" ? "danger" : run.status === "succeeded" ? "positive" : "accent"}>{runStatusLabel(run.status)}</Badge>
            </Pressable>
          ))}
          {!debug?.runs.length ? <Empty title="No runs yet" detail="Run it manually to test the configuration." /> : null}
        </Card>
        <ErrorNotice message={error} />
       </Measured>
      </ScrollView>
      <Sheet visible={editing} title={`Edit ${automation.name}`} onClose={() => setEditing(false)}>
        <AutomationEditor automation={automation} onSaved={() => { setEditing(false); void load(); }} />
      </Sheet>
      <Sheet visible={deleting} title={`Delete ${automation.name}?`} onClose={() => setDeleting(false)}>
        <View style={styles.confirm}>
          <Text style={{ color: theme.muted, lineHeight: 21 }}>It stops firing immediately. Runs already created remain in the record.</Text>
          <Button label="Delete automation" tone="danger" onPress={async () => { await store.mutate((api) => api.deleteAutomation(automation.id)); router.replace("/(app)/automations"); }} />
        </View>
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  grow: { flex: 1 },
  scroll: { padding: 16, paddingBottom: 34 },
  measured: { gap: 12 },
  card: { padding: 14, gap: 11 },
  titleRow: { flexDirection: "row", gap: 10 },
  name: { fontSize: 20, fontWeight: "700", marginBottom: 4 },
  meta: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  actions: { flexDirection: "row", flexWrap: "wrap", gap: 7 },
  section: { fontSize: 13, fontWeight: "600", marginTop: 6 },
  instructions: { padding: 14, gap: 8 },
  runRow: { minHeight: 62, flexDirection: "row", alignItems: "center", gap: 10, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  confirm: { padding: 18, gap: 16 },
});
