import { useEffect, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useLocalSearchParams, useRouter } from "expo-router";

import type { AutomationDebug, WatchTestResult } from "@client/types";
import { Badge, Button, Card, Empty, ErrorNotice, Measured } from "@/components/ui";
import { relative, runStatusLabel, triggerLabel, watchValidated } from "@/lib/format";
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
  const [error, setError] = useState("");
  const [testing, setTesting] = useState(false);
  const [test, setTest] = useState<WatchTestResult>();

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
      <Stack.Screen options={{ title: automation.name }} />
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
            <Button label="Run now" compact disabled={!automation.enabled} onPress={async () => { await store.mutate((api) => api.runAutomation(automation.id), true, (run) => { if (run.run_id) router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.run_id } }); void load(); }); }} />
            <Button
              label={automation.enabled ? "Pause" : "Resume"}
              compact
              tone="secondary"
              onPress={async () => {
                setError("");
                try {
                  // Resuming a watch the relay has not validated is refused,
                  // and a refusal nobody sees looks like a dead button.
                  await store.mutate((api) => api.updateAutomation(automation.id, { ...automation, enabled: !automation.enabled }));
                } catch (caught) {
                  setError(caught instanceof Error ? caught.message : String(caught));
                }
              }}
            />
            {automation.trigger.type === "watch" ? (
              <Button
                label="Test watch"
                compact
                tone="secondary"
                busy={testing}
                onPress={async () => {
                  setTesting(true);
                  setError("");
                  try {
                    // Runs the command and records what it printed, without
                    // firing the action.
                    await store.mutate((api) => api.testAutomation(automation.id), true, setTest);
                  } catch (caught) {
                    setError(caught instanceof Error ? caught.message : String(caught));
                  } finally {
                    setTesting(false);
                  }
                }}
              />
            ) : null}
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
        {automation.enabled && automation.blocked_reason ? (
          <Card style={styles.instructions}>
            <Text style={{ color: theme.danger, fontWeight: "700" }}>Blocked, retrying automatically</Text>
            <Text selectable style={{ color: theme.danger, lineHeight: 20 }}>
              {automation.blocked_reason}
            </Text>
            <Text style={{ color: theme.muted, lineHeight: 20 }}>
              {automation.retry_at ? `Next retry ${relative(automation.retry_at)}. ` : ""}
              Fix the configuration, or pause the automation to stop the obligation.
            </Text>
          </Card>
        ) : automation.enabled && automation.overdue_since ? (
          <Card style={styles.instructions}>
            <Text style={{ color: theme.danger, fontWeight: "700" }}>Overdue</Text>
            <Text style={{ color: theme.muted, lineHeight: 20 }}>
              Work due {relative(automation.overdue_since)} is still waiting for durable acceptance. Patchwork will keep retrying.
            </Text>
          </Card>
        ) : null}
        {/* A watch that quietly stopped working is the failure worth surfacing,
            so its command, its last good check and its last error sit together. */}
        {automation.trigger.type === "watch" ? (
          <Card style={styles.instructions}>
            <Text style={{ color: theme.text, fontWeight: "700" }}>Command</Text>
            <Text selectable style={{ color: theme.muted, fontFamily: "monospace" }}>{automation.trigger.command}</Text>
            <View style={styles.meta}>
              <Badge tone={automation.failure_count ? "danger" : automation.last_success_at ? "positive" : "caution"}>
                {automation.last_success_at ? `Last good check ${relative(automation.last_success_at)}` : "No good check yet"}
              </Badge>
              <Badge tone={watchValidated(automation) ? "positive" : "caution"}>
                {watchValidated(automation)
                  ? `Validated${automation.last_validated_at ? ` ${relative(automation.last_validated_at)}` : ""}`
                  : "Not validated"}
              </Badge>
              {automation.failure_count ? (
                <Badge tone="danger">{automation.failure_count} failed in a row</Badge>
              ) : null}
            </View>
            {automation.last_error ? (
              <Text selectable style={{ color: theme.danger, lineHeight: 20 }}>
                Failed {relative(automation.last_error_at)}: {automation.last_error}
              </Text>
            ) : null}
            {test ? (
              <Text style={{ color: test.ok ? theme.positive : theme.danger, lineHeight: 20 }}>
                {test.ok
                  ? `Tested ${relative(test.tested_at)}: the command ran and printed ${test.event_count} event${test.event_count === 1 ? "" : "s"}. Nothing was fired.`
                  : `Tested ${relative(test.tested_at)}, and it failed: ${test.error ?? "no diagnostic"}`}
              </Text>
            ) : null}
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
});
