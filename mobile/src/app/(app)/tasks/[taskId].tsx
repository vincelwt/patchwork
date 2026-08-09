import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";

import { Conversation } from "@/components/Message";
import { TaskEditor } from "@/components/TaskEditor";
import { Avatar, Badge, Button, Card, ErrorNotice, PageHeader, Sheet } from "@/components/ui";
import { taskStatusLabel } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { isTerminalTaskStatus } from "@client/types";

export default function TaskScreen() {
  const { taskId } = useLocalSearchParams<{ taskId: string }>();
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const task = data?.tasks.find((item) => item.id === taskId);
  const owner = data?.members.find((member) => member.id === task?.owner_id);
  const project = data?.projects.find((item) => item.id === task?.project_id);
  const activeRun = task?.current_run_id
    ? workspace.runDetails[task.current_run_id]?.run ?? data?.active_runs.find((run) => run.id === task.current_run_id)
    : undefined;
  const [editing, setEditing] = useState(false);
  const [agents, setAgents] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!task || !data) return <View style={styles.fill}><PageHeader title="Task" back /></View>;

  const start = async (agentId?: string) => {
    setBusy(true);
    setError("");
    try {
      const run = await store.mutate((api) => api.runTask(task.id, { agent_id: agentId }));
      setAgents(false);
      router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  const active = activeRun && !["succeeded", "failed", "cancelled"].includes(activeRun.status);

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader title={task.key} subtitle={task.title} back action={<Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} />} />
      <Card style={styles.summary}>
        <View style={styles.titleRow}>
          <Text style={[styles.title, { color: theme.text }]}>{task.title}</Text>
          <Badge tone={task.status === "blocked" ? "danger" : task.status === "review" ? "caution" : task.status === "done" ? "positive" : task.status === "canceled" ? "neutral" : "accent"}>{taskStatusLabel(task.status)}</Badge>
        </View>
        {task.outcome ? <Text style={[styles.outcome, { color: theme.muted }]} numberOfLines={5}>{task.outcome}</Text> : null}
        <View style={styles.meta}>
          {owner ? <View style={styles.person}><Avatar member={owner} size={25} /><Text style={{ color: theme.text }}>{owner.display_name}</Text></View> : <Text style={{ color: theme.faint }}>Unassigned</Text>}
          {project ? <Badge>{project.name}</Badge> : null}
          {task.due_at ? <Badge tone={task.due_at < Date.now() && !isTerminalTaskStatus(task.status) ? "danger" : "caution"}>Due {new Date(task.due_at).toLocaleDateString()}</Badge> : null}
        </View>
        <View style={styles.actions}>
          {active ? (
            <>
              <Button label="Run details" compact tone="secondary" onPress={() => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: activeRun.id } })} />
              <Button label="Stop" compact tone="danger" busy={busy} onPress={() => void store.mutate((api) => api.cancelRun(activeRun.id))} />
            </>
          ) : !isTerminalTaskStatus(task.status) ? (
            <Button
              label={activeRun?.status === "failed" ? "Retry" : "Start"}
              compact
              busy={busy}
              onPress={() => (owner?.kind === "agent" ? void start(owner.id) : setAgents(true))}
            />
          ) : (
            <Button label="Reopen" compact tone="secondary" onPress={() => void store.mutate((api) => api.updateTask(task.id, { status: "planned" }))} />
          )}
          {!isTerminalTaskStatus(task.status) && !active ? <Button label="Complete" compact tone="quiet" onPress={() => void store.mutate((api) => api.updateTask(task.id, { status: "done" }))} /> : null}
        </View>
        <ErrorNotice message={error} />
      </Card>
      <View style={[styles.discussionHead, { borderBottomColor: theme.line }]}>
        <Text style={[styles.discussionTitle, { color: theme.text }]}>Discussion</Text>
      </View>
      <Conversation channelId={task.discussion_channel_id} />

      <Sheet visible={editing} title={`Edit ${task.key}`} onClose={() => setEditing(false)}>
        <TaskEditor task={task} onSaved={() => setEditing(false)} />
      </Sheet>
      <Sheet visible={agents} title="Choose an agent" onClose={() => setAgents(false)}>
        <View style={styles.agentList}>
          {data.members.filter((member) => member.kind === "agent").map((agent) => (
            <Pressable key={agent.id} onPress={() => void start(agent.id)} style={[styles.agentRow, { borderBottomColor: theme.line }]}>
              <Avatar member={agent} />
              <View style={styles.fill}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{agent.display_name}</Text>
                <Text style={{ color: theme.muted }}>{agent.agent?.description || agent.agent?.runtime}</Text>
              </View>
            </Pressable>
          ))}
        </View>
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  summary: { margin: 12, padding: 14, gap: 10 },
  titleRow: { flexDirection: "row", gap: 10, alignItems: "flex-start" },
  title: { flex: 1, fontSize: 19, fontWeight: "700", lineHeight: 25 },
  outcome: { fontSize: 14, lineHeight: 20 },
  meta: { flexDirection: "row", flexWrap: "wrap", alignItems: "center", gap: 9 },
  person: { flexDirection: "row", alignItems: "center", gap: 6 },
  actions: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  discussionHead: { paddingHorizontal: 16, paddingVertical: 8, borderBottomWidth: StyleSheet.hairlineWidth },
  discussionTitle: { fontSize: 13, fontWeight: "700" },
  agentList: { paddingBottom: 20 },
  agentRow: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 10, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
});
