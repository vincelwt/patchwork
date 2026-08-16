import { useState } from "react";
import { FlatList, Pressable, RefreshControl, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import type { SymbolViewProps } from "expo-symbols";

import { groupInbox, unreadInboxCount } from "@client/inbox";
import type { InboxGroup } from "@client/inbox";
import type { InboxKind } from "@client/types";
import { Conversation } from "@/components/Message";
import { TaskDetail } from "@/components/TaskDetail";
import { Avatar, Button, Empty, Icon, Measured, Screen } from "@/components/ui";
import { relative } from "@/lib/format";
import { useLayout } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme, type Palette } from "@/lib/theme";

export default function InboxScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const insets = useSafeAreaInsets();
  const { split, gutter } = useLayout();
  const [selected, setSelected] = useState<string>();
  const groups = groupInbox(workspace.bootstrap?.inbox ?? []);
  const unread = unreadInboxCount(workspace.bootstrap?.inbox ?? []);
  // Beside the list, something is always on screen rather than a blank pane.
  const openedGroup = groups.find((group) => group.key === selected)
    ?? (split ? groups.find((group) => group.latest.task_id || group.latest.channel_id) : undefined);
  const opened = openedGroup?.latest;
  const openedChannel = opened?.channel_id && !opened.task_id
    ? workspace.bootstrap?.channels.find((channel) => channel.id === opened.channel_id)
    : undefined;

  const open = async (group: InboxGroup) => {
    const item = group.latest;
    const unreadIds = group.items.filter((candidate) => !candidate.read_at).map((candidate) => candidate.id);
    if (unreadIds.length) {
      await store.mutate(
        (api) => Promise.all(unreadIds.map((id) => api.markRead(id))),
        false,
      ).catch(() => undefined);
    }
    if (item.kind === "question" && item.run_id) {
      const question = workspace.bootstrap?.open_questions.find((candidate) => candidate.run_id === item.run_id);
      if (question) return router.push({ pathname: "/(app)/questions/[questionId]", params: { questionId: question.id } });
    }
    // Beside the list a task or conversation opens in place; a run, question or
    // automation is deep enough to deserve the whole screen either way.
    if (split && (item.task_id || item.channel_id) && !item.run_id) return setSelected(group.key);
    if (item.task_id) return router.push({ pathname: "/tasks/[taskId]", params: { taskId: item.task_id } });
    if (item.run_id) return router.push({ pathname: "/(app)/runs/[runId]", params: { runId: item.run_id } });
    if (item.channel_id) return router.push({ pathname: "/channels/[channelId]", params: { channelId: item.channel_id } });
    if (item.automation_id) return router.push({ pathname: "/(app)/automations/[automationId]", params: { automationId: item.automation_id } });
  };

  const row = ({ item: group }: { item: InboxGroup }) => {
    const item = group.latest;
    const actor = workspace.bootstrap?.members.find((member) => member.id === item.actor_id);
    const kind = describe(group.lead, theme);
    const active = split && openedGroup?.key === group.key;
    const extra = group.items.length - 1;
    return (
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ selected: active }}
        accessibilityLabel={`${kind.label}. ${item.title}`}
        onPress={() => void open(group)}
        style={({ pressed }) => [
          styles.row,
          { borderBottomColor: theme.line },
          active && { backgroundColor: theme.accentSoft },
          pressed && { opacity: 0.6 },
        ]}
      >
        {/* An unread mark reads faster than tinting the whole row. */}
        <View style={[styles.unread, group.unread > 0 && { backgroundColor: theme.accent }]} />
        <View>
          <Avatar member={actor} size={38} />
          {/* The reason it arrived matters as much as who sent it. */}
          <View style={[styles.kindMark, { backgroundColor: kind.colour, borderColor: theme.surface }]}>
            <Icon name={kind.icon} color={theme.surface} size={11} />
          </View>
        </View>
        <View style={styles.main}>
          <Text numberOfLines={split ? 2 : 1} style={[styles.title, { color: theme.text }]}>{item.title}</Text>
          {item.preview ? <Text numberOfLines={2} style={[styles.preview, { color: theme.muted }]}>{item.preview}</Text> : null}
          <View style={styles.foot}>
            <Text numberOfLines={1} style={[styles.kindLabel, { color: kind.colour }]}>{kind.label}</Text>
            {extra > 0 ? (
              <Text numberOfLines={1} style={[styles.more, { color: theme.faint }]}>+{extra} more</Text>
            ) : null}
            <Text style={[styles.time, { color: theme.faint }]}>{relative(item.created_at)}</Text>
          </View>
        </View>
        {split ? null : (
          <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
        )}
      </Pressable>
    );
  };

  const inlineTitle = !split;
  const readAll = unread
    ? <Button label="Read all" compact tone="quiet" onPress={() => void store.mutate((api) => api.markAllRead())} />
    : null;

  const list = (
    <FlatList
      contentInsetAdjustmentBehavior="automatic"
      data={groups}
      keyExtractor={(group) => group.key}
      // The first row carries the title, so nothing is centred under it.
      contentContainerStyle={groups.length || inlineTitle ? styles.list : styles.emptyList}
      // One list, one column. Grouping each row into its own card is what a
      // phone on its side used to do, and it looked like scattered receipts.
      renderItem={split ? row : ({ item }) => <Measured>{row({ item })}</Measured>}
      ListHeaderComponent={
        inlineTitle ? (
          <Measured>
            <View style={[styles.titleRow, { paddingTop: insets.top + 8 }]}>
              <Text accessibilityRole="header" style={[styles.screenTitle, { color: theme.text }]}>Inbox</Text>
              {readAll}
            </View>
          </Measured>
        ) : (
          <Text style={[styles.paneTitle, { color: theme.text }]}>Inbox</Text>
        )
      }
      ListEmptyComponent={<Empty title="Nothing needs you" detail="Mentions, questions, reviews, and failed automations appear here." />}
      refreshControl={<RefreshControl refreshing={workspace.connection === "connecting"} onRefresh={() => void store.refresh()} />}
      showsVerticalScrollIndicator={!split}
    />
  );

  return (
    <Screen style={{ backgroundColor: theme.surface }}>
      <Stack.Screen
        options={{
          // UIKit cannot place bar buttons beside a large title, so the phone
          // draws that row itself and skips the otherwise-empty compact bar.
          headerShown: !inlineTitle,
          headerTransparent: false,
          headerRight: inlineTitle || !readAll ? undefined : () => readAll,
        }}
      />
      {split ? (
        <View style={styles.split}>
          <View style={[styles.pane, { borderRightColor: theme.line }]}>{list}</View>
          <View style={styles.detail}>
            {opened?.task_id ? (
              <TaskDetail taskId={opened.task_id} embedded />
            ) : openedChannel ? (
              <>
                <View style={[styles.detailHead, { borderBottomColor: theme.line, paddingHorizontal: gutter }]}>
                  <Text numberOfLines={1} style={[styles.detailTitle, { color: theme.text }]}>
                    {openedChannel.kind === "channel" ? `# ${openedChannel.name}` : openedChannel.name}
                  </Text>
                </View>
                <Conversation channelId={openedChannel.id} />
              </>
            ) : (
              <View style={styles.centre}>
                <Empty title="Nothing selected" detail="Pick something from the list to read it here." />
              </View>
            )}
          </View>
        </View>
      ) : (
        list
      )}
    </Screen>
  );
}

/// Why this landed in the inbox, said once in words and once in colour.
function describe(kind: InboxKind, theme: Palette): {
  label: string;
  colour: string;
  icon: SymbolViewProps["name"];
} {
  switch (kind) {
    case "mention":
      return { label: "Mentioned you", colour: theme.accent, icon: { ios: "at", android: "alternate_email", web: "alternate_email" } };
    case "reply":
      return { label: "Replied", colour: theme.accent, icon: { ios: "arrowshape.turn.up.left.fill", android: "reply", web: "reply" } };
    case "direct_message":
      return { label: "Direct message", colour: theme.accent, icon: { ios: "bubble.left.fill", android: "chat_bubble", web: "chat_bubble" } };
    case "question":
      return { label: "Needs your answer", colour: theme.caution, icon: { ios: "questionmark", android: "help", web: "help" } };
    case "task_assigned":
      return { label: "Assigned to you", colour: theme.positive, icon: { ios: "person.fill.badge.plus", android: "person_add", web: "person_add" } };
    case "task_blocked":
      return { label: "Blocked", colour: theme.danger, icon: { ios: "exclamationmark.triangle.fill", android: "warning", web: "warning" } };
    case "task_due":
      return { label: "Due", colour: theme.caution, icon: { ios: "clock.fill", android: "schedule", web: "schedule" } };
    case "review_ready":
      return { label: "Ready for review", colour: theme.caution, icon: { ios: "eye.fill", android: "visibility", web: "visibility" } };
    case "automation_failed":
      return { label: "Automation failed", colour: theme.danger, icon: { ios: "bolt.slash.fill", android: "bolt", web: "bolt" } };
  }
}

const styles = StyleSheet.create({
  list: { paddingBottom: 24 },
  emptyList: { flexGrow: 1, justifyContent: "center" },
  titleRow: { minHeight: 64, flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingBottom: 8 },
  screenTitle: { fontSize: 34, fontWeight: "700", letterSpacing: -0.8 },
  split: { flex: 1, flexDirection: "row" },
  pane: { width: 360, borderRightWidth: StyleSheet.hairlineWidth },
  paneTitle: { fontSize: 26, fontWeight: "700", letterSpacing: -0.6, paddingHorizontal: 16, paddingTop: 14, paddingBottom: 8 },
  detail: { flex: 1 },
  detailHead: { paddingTop: 13, paddingBottom: 11, borderBottomWidth: StyleSheet.hairlineWidth },
  detailTitle: { fontSize: 19, fontWeight: "700", letterSpacing: -0.3 },
  centre: { flex: 1, justifyContent: "center" },
  row: { minHeight: 80, flexDirection: "row", alignItems: "center", gap: 11, paddingLeft: 6, paddingRight: 16, paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  unread: { width: 8, height: 8, borderRadius: 4 },
  kindMark: {
    position: "absolute",
    right: -5,
    bottom: -4,
    width: 19,
    height: 19,
    borderRadius: 10,
    borderWidth: 2,
    alignItems: "center",
    justifyContent: "center",
  },
  main: { flex: 1, minWidth: 0, gap: 3 },
  title: { fontSize: 15, fontWeight: "700", lineHeight: 20 },
  preview: { fontSize: 14, lineHeight: 19 },
  foot: { flexDirection: "row", alignItems: "baseline", gap: 8 },
  time: { fontSize: 12 },
  kindLabel: { flexShrink: 1, fontSize: 12, fontWeight: "600" },
  more: { flexShrink: 1, fontSize: 12 },
});
