import { FlatList, Pressable, RefreshControl, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import type { InboxItem } from "@client/types";
import { Avatar, Badge, Button, Empty, PageHeader, Screen } from "@/components/ui";
import { relative } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function InboxScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const items = [...(workspace.bootstrap?.inbox ?? [])].sort((a, b) => b.created_at - a.created_at);
  const unread = items.filter((item) => !item.read_at).length;

  const open = async (item: InboxItem) => {
    if (!item.read_at) await store.mutate((api) => api.markRead(item.id), false).catch(() => undefined);
    if (item.kind === "question" && item.run_id) {
      const question = workspace.bootstrap?.open_questions.find((candidate) => candidate.run_id === item.run_id);
      if (question) return router.push({ pathname: "/(app)/questions/[questionId]", params: { questionId: question.id } });
    }
    if (item.task_id) return router.push({ pathname: "/(app)/tasks/[taskId]", params: { taskId: item.task_id } });
    if (item.run_id) return router.push({ pathname: "/(app)/runs/[runId]", params: { runId: item.run_id } });
    if (item.channel_id) return router.push({ pathname: "/(app)/channels/[channelId]", params: { channelId: item.channel_id } });
    if (item.automation_id) return router.push({ pathname: "/(app)/automations/[automationId]", params: { automationId: item.automation_id } });
  };

  return (
    <Screen>
      <PageHeader
        title="Inbox"
        subtitle={unread ? `${unread} unread` : "You are caught up"}
        action={unread ? <Button label="Read all" compact tone="quiet" onPress={() => void store.mutate((api) => api.markAllRead())} /> : undefined}
      />
      <FlatList
        data={items}
        keyExtractor={(item) => item.id}
        contentContainerStyle={items.length ? styles.list : styles.empty}
        renderItem={({ item }) => {
          const actor = workspace.bootstrap?.members.find((member) => member.id === item.actor_id);
          return (
            <Pressable
              onPress={() => void open(item)}
              style={({ pressed }) => [
                styles.row,
                { backgroundColor: item.read_at ? theme.bg : theme.accentSoft, borderBottomColor: theme.line },
                pressed && { opacity: 0.6 },
              ]}
            >
              <Avatar member={actor} />
              <View style={styles.main}>
                <View style={styles.head}>
                  <Text numberOfLines={1} style={[styles.title, { color: theme.text }]}>{item.title}</Text>
                  <Badge tone={item.kind === "question" ? "caution" : "neutral"}>{label(item)}</Badge>
                </View>
                {item.preview ? <Text numberOfLines={2} style={[styles.preview, { color: theme.muted }]}>{item.preview}</Text> : null}
                <Text style={[styles.time, { color: theme.faint }]}>{relative(item.created_at)}</Text>
              </View>
            </Pressable>
          );
        }}
        ListEmptyComponent={<Empty title="Nothing needs you" detail="Mentions, questions, reviews, and failed automations appear here." />}
        refreshControl={<RefreshControl refreshing={workspace.connection === "connecting"} onRefresh={() => void store.refresh()} />}
      />
    </Screen>
  );
}

function label(item: InboxItem) {
  return item.kind.replaceAll("_", " ");
}

const styles = StyleSheet.create({
  list: { paddingBottom: 24 },
  empty: { flexGrow: 1, justifyContent: "center" },
  row: { flexDirection: "row", gap: 11, padding: 14, borderBottomWidth: StyleSheet.hairlineWidth },
  main: { flex: 1, gap: 4 },
  head: { flexDirection: "row", alignItems: "center", gap: 8 },
  title: { flex: 1, fontSize: 15, fontWeight: "700" },
  preview: { fontSize: 14, lineHeight: 19 },
  time: { fontSize: 11 },
});
