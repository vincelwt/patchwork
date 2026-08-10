import { useMemo, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import type { Id, Member, Task, TaskStatus } from "@client/types";
import { TASK_STATUSES } from "@client/types";
import { TaskEditor } from "@/components/TaskEditor";
import { PullRequestLink } from "@/components/pull-request-link";
import { Avatar, Badge, ChoiceField, Empty, Icon, Measured, Sheet } from "@/components/ui";
import { relative, taskStatusLabel } from "@/lib/format";
import { useLayout } from "@/lib/layout";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { TaskDetail } from "@/components/TaskDetail";

export default function TasksScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const { split } = useLayout();
  const data = workspace.bootstrap;
  const [creating, setCreating] = useState(false);
  const [owner, setOwner] = useState("");
  const [status, setStatus] = useState("");
  const [selected, setSelected] = useState<Id>();
  const tasks = useMemo(
    () =>
      (data?.tasks ?? [])
        .filter((task) => (!owner || task.owner_id === owner) && (!status || task.status === status))
        .sort((a, b) => (a.due_at ?? Number.MAX_SAFE_INTEGER) - (b.due_at ?? Number.MAX_SAFE_INTEGER) || b.updated_at - a.updated_at),
    [data?.tasks, owner, status],
  );

  if (!data) return <Empty title="Loading tasks" />;

  const open = (task: Task) =>
    split ? setSelected(task.id) : router.push({ pathname: "/tasks/[taskId]", params: { taskId: task.id } });

  const groups = (
    <>
      {/* The filters scroll with the list so the navigation bar keeps its own row. */}
      <View style={styles.filters}>
        <View style={styles.filter}>
          <ChoiceField
            value={status}
            placeholder="Any status"
            options={[{ value: "", label: "Any status" }, ...TASK_STATUSES.map((item) => ({ value: item, label: taskStatusLabel(item) }))]}
            onChange={setStatus}
          />
        </View>
        <View style={styles.filter}>
          <ChoiceField
            value={owner}
            placeholder="Anyone"
            options={[{ value: "", label: "Anyone" }, ...data.members.map((member) => ({ value: member.id, label: member.display_name }))]}
            onChange={setOwner}
          />
        </View>
      </View>
      {TASK_STATUSES.map((group) => {
        const items = tasks.filter((task) => task.status === group);
        if (!items.length) return null;
        return (
          <View key={group} style={styles.group}>
            <View style={styles.groupHead}>
              <Text style={[styles.groupTitle, { color: theme.faint }]}>{taskStatusLabel(group)}</Text>
              <Badge tone={statusTone(group)}>{items.length}</Badge>
            </View>
            {items.map((task) => (
              <TaskRow key={task.id} task={task} active={split && task.id === selected} onPress={() => open(task)} />
            ))}
          </View>
        );
      })}
      {!tasks.length ? <Empty title="No matching tasks" detail="Clear a filter or create the first task." /> : null}
    </>
  );

  const list = (
    <ScrollView
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.scroll}
      showsVerticalScrollIndicator={!split}
    >
      {split ? (
        <>
          <Text style={[styles.paneTitle, { color: theme.text }]}>Tasks</Text>
          {groups}
        </>
      ) : (
        <Measured>{groups}</Measured>
      )}
    </ScrollView>
  );

  return (
    <View style={[styles.fill, { backgroundColor: theme.surface }]}>
      <Stack.Screen
        options={{
          // Beside a detail pane the bar stays opaque, so neither column slides
          // under it and no column has to guess the bar's height.
          headerLargeTitle: !split,
          headerTransparent: !split,
          headerRight: () => (
            <Pressable accessibilityRole="button" accessibilityLabel="New task" hitSlop={8} onPress={() => setCreating(true)}>
              <Icon name={{ ios: "plus", android: "add", web: "add" }} color={theme.accent} size={23} />
            </Pressable>
          ),
        }}
      />
      {split ? (
        <View style={styles.split}>
          <View style={[styles.pane, { borderRightColor: theme.line }]}>{list}</View>
          <View style={styles.detail}>
            {selected ? (
              <TaskDetail taskId={selected} embedded />
            ) : (
              <View style={styles.centre}>
                <Empty title="Pick a task" detail="The task and its discussion open beside the list." />
              </View>
            )}
          </View>
        </View>
      ) : (
        list
      )}
      <Sheet visible={creating} title="New task" onClose={() => setCreating(false)}>
        <TaskEditor
          onSaved={(task) => {
            setCreating(false);
            open(task);
          }}
        />
      </Sheet>
    </View>
  );
}

function TaskRow({ task, active, onPress }: { task: Task; active?: boolean; onPress: () => void }) {
  const theme = useTheme();
  const data = useWorkspace().bootstrap;
  const owner = data?.members.find((member) => member.id === task.owner_id);
  const project = data?.projects.find((item) => item.id === task.project_id);
  // A task can hold several agents at once. Two of them must not look like
  // one, so the row shows a face each once there is more than one.
  const working = (data?.active_runs ?? [])
    .filter((run) => run.task_id === task.id)
    .sort((a, b) => a.created_at - b.created_at)
    .map((run) => data?.members.find((member) => member.id === run.agent_id))
    .filter((member, index, all): member is Member => !!member && all.indexOf(member) === index);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected: active }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        { borderBottomColor: theme.line },
        active && { backgroundColor: theme.accentSoft },
        pressed && { opacity: 0.6 },
      ]}
    >
      <View style={styles.main}>
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>{task.title}</Text>
        <View style={styles.metaRow}>
          <Text style={[styles.key, { color: theme.faint }]}>{task.key}</Text>
          <Text numberOfLines={1} style={[styles.meta, { color: theme.muted }]}>
            {[project?.name, task.due_at ? `due ${new Date(task.due_at).toLocaleDateString()}` : "", relative(task.updated_at)].filter(Boolean).join(" · ")}
          </Text>
          <PullRequestLink task={task} />
        </View>
      </View>
      {working.length > 1 ? (
        <View style={styles.faces}>
          {working.map((member) => <Avatar key={member.id} member={member} size={24} />)}
        </View>
      ) : owner ? <Avatar member={owner} size={28} /> : null}
      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
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
  split: { flex: 1, flexDirection: "row" },
  pane: { width: 360, borderRightWidth: StyleSheet.hairlineWidth },
  paneTitle: { fontSize: 26, fontWeight: "700", letterSpacing: -0.6, paddingHorizontal: 16, paddingTop: 14, paddingBottom: 6 },
  detail: { flex: 1 },
  centre: { flex: 1, justifyContent: "center" },
  filters: { flexDirection: "row", gap: 8, paddingHorizontal: 16, paddingTop: 4, paddingBottom: 12 },
  filter: { flex: 1 },
  scroll: { paddingBottom: 30 },
  group: { marginBottom: 18 },
  groupHead: { minHeight: 32, flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 16 },
  groupTitle: { fontSize: 13, fontWeight: "600" },
  faces: { flexDirection: "row", alignItems: "center", gap: 3 },
  row: { minHeight: 64, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 10 },
  key: { fontSize: 12, fontWeight: "700" },
  main: { flex: 1, minWidth: 0 },
  title: { fontSize: 15, fontWeight: "600", lineHeight: 20 },
  metaRow: { flexDirection: "row", flexWrap: "wrap", alignItems: "center", gap: 7, paddingTop: 3 },
  meta: { flexShrink: 1, fontSize: 12 },
});
