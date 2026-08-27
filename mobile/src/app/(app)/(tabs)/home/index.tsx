import { FlatList, Pressable, RefreshControl, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { groupInbox, unreadInboxCount } from "@client/inbox";
import type { InboxGroup } from "@client/inbox";
import type { Ask, InboxItem, InboxKind } from "@client/types";
import { AskCard } from "@/components/AskCard";
import { Avatar, Button, Empty, Icon, Measured, Screen } from "@/components/ui";
import { relative } from "@/lib/format";
import { autoTopInset } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

/// Why something arrived, now that only three things can.
const KIND: Record<InboxKind, string> = {
  ask: "Needs your answer",
  automation_failed: "Automation failed",
  mention: "Mentioned you",
};

export default function HomeScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const insets = useSafeAreaInsets();
  const data = workspace.bootstrap;
  const groups = groupInbox(data?.inbox ?? []);
  const unread = unreadInboxCount(data?.inbox ?? []);
  const open = data?.open_asks ?? [];
  // An open ask is the only thing anybody is actually waiting on, so the asks
  // lead in the inbox's own urgency order and an answered one leaves the screen
  // rather than sinking into the activity below it.
  const ordered = groups.flatMap((group) => {
    const ask = group.lead === "ask" ? openAskFor(group.latest, open) : undefined;
    return ask ? [ask] : [];
  });
  const asks = [...ordered, ...open.filter((ask) => !ordered.includes(ask))];
  const activity = groups.filter((group) => group.lead !== "ask");

  const openGroup = async (group: InboxGroup) => {
    const item = group.latest;
    const unreadIds = group.items.filter((candidate) => !candidate.read_at).map((candidate) => candidate.id);
    if (unreadIds.length) {
      await store.mutate(
        (api) => Promise.all(unreadIds.map((id) => api.markRead(id))),
        false,
      ).catch(() => undefined);
    }
    // What arrived was said somewhere, so it opens where it was said. A run's
    // activity log is a drill-down from there, never the destination for
    // something addressed to a person.
    if (item.task_id) return router.push({ pathname: "/tasks/[taskId]", params: { taskId: item.task_id } });
    if (item.channel_id) return router.push({ pathname: "/channels/[channelId]", params: { channelId: item.channel_id } });
    if (item.automation_id) return router.push({ pathname: "/(app)/automations/[automationId]", params: { automationId: item.automation_id } });
    if (item.run_id) return router.push({ pathname: "/(app)/runs/[runId]", params: { runId: item.run_id } });
  };

  return (
    <Screen style={{ backgroundColor: theme.surface }}>
      <Stack.Screen options={{ headerShown: false }} />
      <FlatList
        contentInsetAdjustmentBehavior="automatic"
        data={activity}
        keyExtractor={(group) => group.key}
        contentContainerStyle={styles.list}
        renderItem={({ item }) => (
          <Measured>
            <ActivityRow group={item} onPress={() => void openGroup(item)} />
          </Measured>
        )}
        ListHeaderComponent={
          <Measured>
            <View style={[styles.titleRow, { paddingTop: (autoTopInset ? 0 : insets.top) + 8 }]}>
              <Text accessibilityRole="header" style={[styles.screenTitle, { color: theme.text }]}>Home</Text>
              {unread ? (
                <Button label="Read all" compact tone="quiet" onPress={() => void store.mutate((api) => api.markAllRead())} />
              ) : null}
            </View>
            <View style={styles.asks}>
              {asks.map((ask) => <AskCard key={ask.id} ask={ask} />)}
            </View>
            {asks.length && activity.length ? (
              <Text style={[styles.section, { color: theme.faint }]}>Activity</Text>
            ) : null}
          </Measured>
        }
        ListEmptyComponent={
          asks.length ? null : (
            <Empty title="Nothing needs you" detail="Asks from your agents, mentions, and failed automations appear here." />
          )
        }
        refreshControl={<RefreshControl refreshing={workspace.connection === "connecting"} onRefresh={() => void store.refresh()} />}
      />
    </Screen>
  );
}

function ActivityRow({ group, onPress }: { group: InboxGroup; onPress: () => void }) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const item = group.latest;
  const actor = workspace.bootstrap?.members.find((member) => member.id === item.actor_id);
  const extra = group.items.length - 1;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${KIND[group.lead]}. ${item.title}`}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        { borderBottomColor: theme.line },
        pressed && { opacity: 0.6 },
      ]}
    >
      {/* An unread mark reads faster than tinting the whole row. */}
      <View style={[styles.unread, group.unread > 0 && { backgroundColor: theme.accent }]} />
      <Avatar member={actor} size={38} />
      <View style={styles.main}>
        <Text numberOfLines={1} style={[styles.title, { color: theme.text }]}>{item.title}</Text>
        {item.preview ? <Text numberOfLines={2} style={[styles.preview, { color: theme.muted }]}>{item.preview}</Text> : null}
        <View style={styles.foot}>
          <Text numberOfLines={1} style={[styles.kindLabel, { color: theme.muted }]}>{KIND[group.lead]}</Text>
          {extra > 0 ? <Text style={[styles.more, { color: theme.faint }]}>+{extra} more</Text> : null}
          <Text style={[styles.time, { color: theme.faint }]}>{relative(item.created_at)}</Text>
        </View>
      </View>
      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
    </Pressable>
  );
}

/// An inbox row names where an ask landed rather than the ask itself, so the
/// open ask is found back through the run, task, or message it came from.
function openAskFor(item: InboxItem, asks: Ask[]): Ask | undefined {
  return asks.find(
    (ask) =>
      (!!item.run_id && ask.run_id === item.run_id) ||
      (!!item.task_id && ask.task_id === item.task_id) ||
      (!!item.message_id && ask.message_id === item.message_id),
  );
}

const styles = StyleSheet.create({
  list: { paddingBottom: 24 },
  titleRow: { minHeight: 64, flexDirection: "row", alignItems: "center", gap: 8, paddingHorizontal: 16, paddingBottom: 8 },
  screenTitle: { flex: 1, fontSize: 34, fontWeight: "700", letterSpacing: -0.8 },
  asks: { paddingHorizontal: 16 },
  section: { fontSize: 13, fontWeight: "600", paddingHorizontal: 16, paddingTop: 18, paddingBottom: 6 },
  row: { minHeight: 80, flexDirection: "row", alignItems: "center", gap: 11, paddingLeft: 6, paddingRight: 16, paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  unread: { width: 8, height: 8, borderRadius: 4 },
  main: { flex: 1, minWidth: 0, gap: 3 },
  title: { fontSize: 15, fontWeight: "700", lineHeight: 20 },
  preview: { fontSize: 14, lineHeight: 19 },
  foot: { flexDirection: "row", alignItems: "baseline", gap: 8 },
  time: { fontSize: 12 },
  kindLabel: { flexShrink: 1, fontSize: 12, fontWeight: "600" },
  more: { flexShrink: 1, fontSize: 12 },
});
