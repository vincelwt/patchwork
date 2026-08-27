import { StyleSheet, Text, View } from "react-native";
import { Stack } from "expo-router";

import { AskCard } from "./AskCard";
import { Conversation } from "./Message";
import { useLayout } from "@/lib/layout";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

/// What the task is called, where it stands, and the one thing being asked of
/// you, pinned over the discussion that is everything else about it. Status is
/// derived from the runs and the ask, so there is nothing here to push.
export function TaskDetail({ taskId }: { taskId: string }) {
  const theme = useTheme();
  const { gutter } = useLayout();
  const task = useWorkspace().bootstrap?.tasks.find((item) => item.id === taskId);

  if (!task) {
    return (
      <View style={styles.fill}>
        <Stack.Screen options={{ title: "Task", headerTransparent: false }} />
      </View>
    );
  }

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen options={{ title: task.key, headerTransparent: false }} />
      <View style={[styles.head, { borderBottomColor: theme.line, paddingHorizontal: gutter }]}>
        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>{task.title}</Text>
        {task.brief ? <Text style={[styles.brief, { color: theme.muted }]}>{task.brief}</Text> : null}
        {task.ask ? <AskCard ask={task.ask} /> : null}
      </View>
      <Conversation channelId={task.discussion_channel_id} />
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  head: { paddingTop: 6, paddingBottom: 11, gap: 5, borderBottomWidth: StyleSheet.hairlineWidth },
  title: { fontSize: 16, fontWeight: "700", lineHeight: 21 },
  brief: { fontSize: 14, lineHeight: 20 },
});
