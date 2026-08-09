import { useMemo, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import type { Task, TaskStatus } from "@client/types";
import { TASK_STATUSES } from "@client/types";
import { TaskEditor } from "@/components/TaskEditor";
import { PullRequestLink } from "@/components/pull-request-link";
import { Avatar, Badge, Button, ChoiceField, Empty, PageHeader, Sheet } from "@/components/ui";
import { relative, taskStatusLabel } from "@/lib/format";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function TasksScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const data = workspace.bootstrap;
  const [creating, setCreating] = useState(false);
  const [owner, setOwner] = useState("");
  const [status, setStatus] = useState("");
  const tasks = useMemo(
    () =>
      (data?.tasks ?? [])
        .filter((task) => (!owner || task.owner_id === owner) && (!status || task.status === status))
        .sort((a, b) => (a.due_at ?? Number.MAX_SAFE_INTEGER) - (b.due_at ?? Number.MAX_SAFE_INTEGER) || b.updated_at - a.updated_at),
    [data?.tasks, owner, status],
  );

  if (!data) return <Empty title="Loading tasks" />;

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader title="Tasks" subtitle={`${tasks.length} shown`} action={<Button label="New task" compact onPress={() => setCreating(true)} />} />
      <View style={[styles.filters, { borderBottomColor: theme.line }]}>
        <View style={styles.filter}><ChoiceField value={status} placeholder="Any status" options={[{ value: "", label: "Any status" }, ...TASK_STATUSES.map((item) => ({ value: item, label: taskStatusLabel(item) }))]} onChange={setStatus} /></View>
        <View style={styles.filter}><ChoiceField value={owner} placeholder="Anyone" options={[{ value: "", label: "Anyone" }, ...data.members.map((member) => ({ value: member.id, label: member.display_name }))]} onChange={setOwner} /></View>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        {TASK_STATUSES.map((group) => {
          const items = tasks.filter((task) => task.status === group);
          if (!items.length) return null;
          return (
            <View key={group} style={styles.group}>
              <View style={styles.groupHead}>
                <Text style={[styles.groupTitle, { color: theme.faint }]}>{taskStatusLabel(group)}</Text>
                <Badge tone={statusTone(group)}>{items.length}</Badge>
              </View>
              {items.map((task) => <TaskRow key={task.id} task={task} />)}
            </View>
          );
        })}
        {!tasks.length ? <Empty title="No matching tasks" detail="Clear a filter or create the first task." /> : null}
      </ScrollView>
      <Sheet visible={creating} title="New task" onClose={() => setCreating(false)}>
        <TaskEditor
          onSaved={(task) => {
            setCreating(false);
            router.push({ pathname: "/(app)/tasks/[taskId]", params: { taskId: task.id } });
          }}
        />
      </Sheet>
    </View>
  );
}

function TaskRow({ task }: { task: Task }) {
  const theme = useTheme();
  const router = useRouter();
  const data = useWorkspace().bootstrap;
  const owner = data?.members.find((member) => member.id === task.owner_id);
  const project = data?.projects.find((item) => item.id === task.project_id);
  return (
    <Pressable
      onPress={() => router.push({ pathname: "/(app)/tasks/[taskId]", params: { taskId: task.id } })}
      style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
    >
      <Text style={[styles.key, { color: theme.faint }]}>{task.key}</Text>
      <View style={styles.main}>
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>{task.title}</Text>
        <View style={styles.metaRow}>
          <Text numberOfLines={1} style={[styles.meta, { color: theme.muted }]}>
            {[project?.name, task.due_at ? `due ${new Date(task.due_at).toLocaleDateString()}` : "", relative(task.updated_at)].filter(Boolean).join(" · ")}
          </Text>
          <PullRequestLink task={task} />
        </View>
      </View>
      {owner ? <Avatar member={owner} size={28} /> : <Text style={{ color: theme.faint }}>Unassigned</Text>}
    </Pressable>
  );
}

function statusTone(status: TaskStatus): "neutral" | "accent" | "positive" | "caution" | "danger" {
  if (status === "running") return "accent";
  if (status === "blocked") return "danger";
  if (status === "review") return "caution";
  if (status === "done") return "positive";
  return "neutral";
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  filters: { flexDirection: "row", gap: 8, paddingHorizontal: 12, paddingVertical: 8, borderBottomWidth: StyleSheet.hairlineWidth },
  filter: { flex: 1 },
  scroll: { padding: 14, paddingBottom: 30 },
  group: { marginBottom: 20 },
  groupHead: { flexDirection: "row", alignItems: "center", gap: 8, marginBottom: 4 },
  groupTitle: { fontSize: 12, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.7 },
  row: { minHeight: 67, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 9 },
  key: { width: 58, fontSize: 12, fontWeight: "700" },
  main: { flex: 1, minWidth: 0 },
  title: { fontSize: 15, fontWeight: "600", lineHeight: 20 },
  metaRow: { flexDirection: "row", flexWrap: "wrap", alignItems: "center", gap: 6, paddingTop: 3 },
  meta: { flexShrink: 1, fontSize: 12 },
});
