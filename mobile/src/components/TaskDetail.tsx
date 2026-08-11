import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import { Conversation } from "./Message";
import { PullRequestLink } from "./pull-request-link";
import { TaskEditor } from "./TaskEditor";
import { Avatar, Badge, Button, ErrorNotice, Sheet } from "./ui";
import { runStatusLabel, taskStatusLabel } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useLayout } from "@/lib/layout";
import { useTheme } from "@/lib/theme";
import { isTerminalTaskStatus } from "@client/types";

/// A run in one of these states is over. Anything else is still on the task,
/// and there can be more than one of those at a time.
const FINISHED = ["succeeded", "failed", "cancelled"];

/// Also rendered beside the list on a wide screen, where the route's own header
/// is not on screen and the task key belongs in the body instead.
export function TaskDetail({ taskId, embedded }: { taskId: string; embedded?: boolean }) {
  const theme = useTheme();
  const { gutter } = useLayout();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const task = data?.tasks.find((item) => item.id === taskId);
  const owner = data?.members.find((member) => member.id === task?.owner_id);
  const project = data?.projects.find((item) => item.id === task?.project_id);
  const currentRun = task?.current_run_id
    ? workspace.runDetails[task.current_run_id]?.run ?? data?.active_runs.find((run) => run.id === task.current_run_id)
    : undefined;
  // Several agents can be inside one task at once, sharing its worktree, so
  // `current_run_id` names the newest run to look at rather than the only one.
  // Oldest first, so an agent keeps its place while another starts or stops.
  const taskRuns = (data?.active_runs ?? [])
    .filter((run) => run.task_id === task?.id && !FINISHED.includes(run.status))
    .sort((a, b) => a.created_at - b.created_at);
  // A run opened from this screen can be fresher than the bootstrap list.
  if (currentRun && !FINISHED.includes(currentRun.status) && !taskRuns.some((run) => run.id === currentRun.id)) {
    taskRuns.push(currentRun);
  }
  // The run the header speaks for: the newest one still going, and otherwise
  // whatever ran last, so "Retry" still knows it is a retry.
  const activeRun = currentRun && !FINISHED.includes(currentRun.status)
    ? currentRun
    : taskRuns[taskRuns.length - 1] ?? currentRun;
  const [editing, setEditing] = useState(false);
  const [agents, setAgents] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!task || !data) {
    return (
      <View style={styles.fill}>
        {embedded ? null : <Stack.Screen options={{ title: "Task", headerTransparent: false }} />}
      </View>
    );
  }

  const start = async (agentId?: string) => {
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) => api.runTask(task.id, { agent_id: agentId }),
        true,
        (run) => {
          setAgents(false);
          router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } });
        },
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  const approve = async () => {
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) => api.approveTask(task.id),
        true,
        (run) => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } }),
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  const active = taskRuns.length > 0;

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      {embedded ? null : (
        <Stack.Screen
          options={{
            title: task.key,
            headerTransparent: false,
            headerRight: () => <Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} />,
          }}
        />
      )}
      {/* One strip under the navigation bar rather than a card floating below
          it: the title, who and when, and what can be done, in three tight
          lines. Everything the task said about itself is in the discussion. */}
      <View style={[styles.head, { borderBottomColor: theme.line, paddingHorizontal: gutter }]}>
        <View style={styles.titleRow}>
          <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>{task.title}</Text>
          {embedded ? <Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} /> : null}
        </View>
        <View style={styles.meta}>
          {embedded ? <Text style={[styles.key, { color: theme.faint }]}>{task.key}</Text> : null}
          <Badge tone={task.status === "blocked" ? "danger" : task.status === "review" ? "caution" : task.status === "done" ? "positive" : task.status === "canceled" ? "neutral" : "accent"}>{taskStatusLabel(task.status)}</Badge>
          {owner ? <View style={styles.person}><Avatar member={owner} size={22} /><Text numberOfLines={1} style={[styles.metaText, { color: theme.muted }]}>{owner.display_name}</Text></View> : <Text style={[styles.metaText, { color: theme.faint }]}>Unassigned</Text>}
          {project ? <Badge>{project.name}</Badge> : null}
          {task.due_at ? <Badge tone={task.due_at < Date.now() && !isTerminalTaskStatus(task.status) ? "danger" : "caution"}>Due {new Date(task.due_at).toLocaleDateString()}</Badge> : null}
          <PullRequestLink task={task} />
        </View>
        {taskRuns.length > 1 ? (
          <View style={styles.runs}>
            {taskRuns.map((run) => {
              const agent = data.members.find((member) => member.id === run.agent_id);
              return (
                <View key={run.id} style={[styles.runRow, { borderTopColor: theme.line }]}>
                  <Avatar member={agent} size={26} />
                  <Pressable
                    style={styles.fill}
                    onPress={() => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } })}
                  >
                    <Text numberOfLines={1} style={{ color: theme.text, fontWeight: "600" }}>{agent?.display_name ?? "Agent"}</Text>
                    <Text numberOfLines={1} style={{ color: theme.muted }}>{run.headline || runStatusLabel(run.status)}</Text>
                  </Pressable>
                  {/* Per run, because one Stop for several agents is a guess. */}
                  <Button label="Stop" compact tone="danger" onPress={() => void store.mutate((api) => api.cancelRun(run.id))} />
                </View>
              );
            })}
          </View>
        ) : null}
        <View style={styles.actions}>
          {active ? (
            taskRuns.length > 1 ? (
              <Button
                label="Stop all"
                compact
                tone="danger"
                busy={busy}
                onPress={() => void store.mutate((api) => Promise.all(taskRuns.map((run) => api.cancelRun(run.id))))}
              />
            ) : (
              <>
                <Button label="Run details" compact tone="secondary" onPress={() => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: taskRuns[0].id } })} />
                <Button label="Stop" compact tone="danger" busy={busy} onPress={() => void store.mutate((api) => api.cancelRun(taskRuns[0].id))} />
              </>
            )
          ) : task.status === "review" ? (
            <>
              <Button
                label={task.review_action ?? "Complete"}
                compact
                busy={busy}
                onPress={() =>
                  task.review_action
                    ? void approve()
                    : void store.mutate((api) => api.updateTask(task.id, { status: "done" }))
                }
              />
              <Button
                label="Back to planning"
                compact
                tone="secondary"
                onPress={() => void store.mutate((api) => api.updateTask(task.id, { status: "planned" }))}
              />
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
          {!isTerminalTaskStatus(task.status) && task.status !== "review" && !active ? <Button label="Complete" compact tone="quiet" onPress={() => void store.mutate((api) => api.updateTask(task.id, { status: "done" }))} /> : null}
        </View>
        <ErrorNotice message={error} />
      </View>
      {/* The outcome opens the history rather than sitting above it: read once,
          then scrolled away like the oldest message. */}
      <Conversation
        channelId={task.discussion_channel_id}
        intro={task.outcome.trim() ? (
          <View style={styles.outcome}>
            <Text style={[styles.outcomeLabel, { color: theme.faint }]}>Outcome</Text>
            <Text style={[styles.outcomeText, { color: theme.muted }]}>{task.outcome.trim()}</Text>
          </View>
        ) : undefined}
      />

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
  key: { fontSize: 12, fontWeight: "700" },
  head: { paddingTop: 6, paddingBottom: 9, gap: 7, borderBottomWidth: StyleSheet.hairlineWidth },
  titleRow: { flexDirection: "row", gap: 8, alignItems: "flex-start" },
  title: { flex: 1, fontSize: 16, fontWeight: "700", lineHeight: 21 },
  meta: { flexDirection: "row", flexWrap: "wrap", alignItems: "center", gap: 8 },
  metaText: { flexShrink: 1, fontSize: 13 },
  person: { flexDirection: "row", alignItems: "center", gap: 5 },
  runs: { gap: 2 },
  runRow: { flexDirection: "row", alignItems: "center", gap: 10, paddingTop: 8, borderTopWidth: StyleSheet.hairlineWidth },
  actions: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  outcome: { paddingVertical: 8, gap: 3 },
  outcomeLabel: { fontSize: 12, fontWeight: "700" },
  outcomeText: { fontSize: 14, lineHeight: 20 },
  agentList: { paddingBottom: 20 },
  agentRow: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 10, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
});
