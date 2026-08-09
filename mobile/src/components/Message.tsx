import { memo, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Linking,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useRouter } from "expo-router";

import type { Id, Message, MessageCard, Run } from "@client/types";
import { dayLabel, runStatusLabel, timeOfDay } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { AttachmentView } from "./Attachment";
import { Composer } from "./Composer";
import { Markdown } from "./Markdown";
import { Avatar, Badge, Button, Empty, Sheet } from "./ui";

const EMOJI = ["👍", "❤️", "🎉", "👀", "✅", "🤔", "🙏", "🚀"];

export function Conversation({ channelId }: { channelId: Id }) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const channel = workspace.bootstrap?.channels.find((item) => item.id === channelId);
  const messages = workspace.messages[channelId] ?? [];
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    void store.loadMessages(channelId);
  }, [channelId, store]);

  if (!channel) return <Empty title="Conversation unavailable" detail="It may have been archived or removed." />;

  const refresh = async () => {
    setRefreshing(true);
    await store.loadMessages(channelId).catch(() => undefined);
    setRefreshing(false);
  };

  return (
    <View style={styles.conversation}>
      <FlatList
        data={messages}
        keyExtractor={(message) => message.id}
        contentContainerStyle={messages.length ? styles.list : styles.emptyList}
        renderItem={({ item, index }) => (
          <View>
            {index === 0 || dayLabel(messages[index - 1].created_at) !== dayLabel(item.created_at) ? (
              <View style={styles.day}>
                <Text style={[styles.dayText, { color: theme.muted, backgroundColor: theme.surface }]}>{dayLabel(item.created_at)}</Text>
              </View>
            ) : null}
            <MessageRow message={item} />
          </View>
        )}
        ListEmptyComponent={<Empty title="Nothing here yet" detail="Say something or mention an agent with @." />}
        ListHeaderComponent={workspace.hasMore[channelId] ? (
          <Button
            label="Load older messages"
            tone="quiet"
            onPress={() => void store.loadMessages(channelId, messages[0]?.id)}
          />
        ) : null}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void refresh()} />}
        initialNumToRender={20}
        windowSize={9}
      />
      <TypingLine channelId={channelId} />
      <Composer channelId={channelId} taskId={channel.task_id} />
    </View>
  );
}

export const MessageRow = memo(function MessageRow({ message, inThread }: { message: Message; inThread?: boolean }) {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const [reactions, setReactions] = useState(false);
  const author = workspace.bootstrap?.members.find((member) => member.id === message.author_id);
  const run = message.run_id
    ? workspace.runDetails[message.run_id]?.run ?? workspace.bootstrap?.active_runs.find((item) => item.id === message.run_id)
    : undefined;

  const react = async (emoji: string) => {
    setReactions(false);
    await store.mutate((api) => api.react(message.id, emoji), false);
  };

  if (message.kind === "status" || message.kind === "system") {
    return (
      <View style={styles.activity}>
        <Text style={{ color: theme.faint }}>•</Text>
        <Text style={[styles.activityText, { color: theme.muted }]}>{message.body}</Text>
      </View>
    );
  }

  return (
    <View style={styles.message}>
      <Avatar member={author} size={32} />
      <View style={styles.messageMain}>
        <View style={styles.messageHead}>
          <Text style={[styles.author, { color: theme.text }]}>{author?.display_name ?? "Unknown"}</Text>
          {author?.kind === "agent" ? <Badge tone="accent">agent</Badge> : null}
          <Text style={[styles.time, { color: theme.faint }]}>{timeOfDay(message.created_at)}</Text>
        </View>
        {run ? <RunLine run={run} /> : null}
        {message.body ? <Markdown body={message.body} /> : null}
        {message.card ? <CardView card={message.card} /> : null}
        {message.attachments.map((attachment) => <AttachmentView key={attachment.id} attachment={attachment} />)}
        {message.reactions.length ? (
          <View style={styles.reactionRow}>
            {message.reactions.map((reaction) => (
              <Pressable
                key={reaction.emoji}
                accessibilityRole="button"
                accessibilityLabel={`${reaction.emoji}, ${reaction.member_ids.length}`}
                onPress={() => void react(reaction.emoji)}
                style={[styles.reaction, { backgroundColor: reaction.member_ids.includes(workspace.bootstrap?.me.id ?? "") ? theme.accentSoft : theme.surface }]}
              >
                <Text>{reaction.emoji} {reaction.member_ids.length}</Text>
              </Pressable>
            ))}
          </View>
        ) : null}
        <View style={styles.messageActions}>
          <Pressable accessibilityRole="button" onPress={() => setReactions(true)} hitSlop={8} style={styles.messageAction}>
            <Text style={{ color: theme.accent }}>React</Text>
          </Pressable>
          {!inThread ? (
            <Pressable accessibilityRole="button" onPress={() => router.push({ pathname: "/(app)/threads/[messageId]", params: { messageId: message.id } })} hitSlop={8} style={styles.messageAction}>
              <Text style={{ color: theme.accent }}>
                {message.reply_count ? `${message.reply_count} ${message.reply_count === 1 ? "reply" : "replies"}` : "Reply"}
              </Text>
            </Pressable>
          ) : null}
        </View>
      </View>
      <Sheet visible={reactions} title="React" onClose={() => setReactions(false)}>
        <View style={styles.emojiGrid}>
          {EMOJI.map((emoji) => (
            <Pressable key={emoji} accessibilityRole="button" accessibilityLabel={`React ${emoji}`} onPress={() => void react(emoji)} style={styles.emoji}>
              <Text style={{ fontSize: 28 }}>{emoji}</Text>
            </Pressable>
          ))}
        </View>
      </Sheet>
    </View>
  );
});

function RunLine({ run }: { run: Run }) {
  const theme = useTheme();
  const router = useRouter();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Agent run, ${runStatusLabel(run.status)}`}
      onPress={() => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } })}
      style={[styles.runLine, { backgroundColor: theme.surface }]}
    >
      {!["succeeded", "failed", "cancelled"].includes(run.status) ? <ActivityIndicator size="small" color={theme.accent} /> : null}
      <Text numberOfLines={1} style={{ color: theme.muted, flex: 1 }}>{run.headline || runStatusLabel(run.status)}</Text>
      <Text style={{ color: run.status === "failed" ? theme.danger : theme.accent }}>{runStatusLabel(run.status)}</Text>
    </Pressable>
  );
}

function CardView({ card }: { card: MessageCard }) {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const content = useMemo(() => {
    switch (card.type) {
      case "task": {
        const task = workspace.bootstrap?.tasks.find((item) => item.id === card.task_id);
        return { title: task?.title ?? "Task", detail: task?.key, press: () => router.push({ pathname: "/tasks/[taskId]", params: { taskId: card.task_id } }) };
      }
      case "run":
        return { title: "Agent run", detail: "Open activity", press: () => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: card.run_id } }) };
      case "question":
        return { title: "Question", detail: "Answer an agent", press: () => router.push({ pathname: "/(app)/questions/[questionId]", params: { questionId: card.question_id } }) };
      case "pull_request":
        return { title: "Pull request", detail: card.url, press: () => void Linking.openURL(card.url) };
      case "artifact":
        return { title: card.caption || "Artifact", detail: "Open on Desktop", press: undefined };
      case "preview":
        return { title: "Preview", detail: "Open on Desktop", press: undefined };
      case "chart":
        return { title: "Chart", detail: card.caption || "Open on Desktop", press: undefined };
    }
  }, [card, router, workspace.bootstrap?.tasks]);
  return (
    <Pressable
      accessibilityRole={content.press ? "button" : undefined}
      disabled={!content.press}
      onPress={content.press}
      style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }]}
    >
      <Text style={[styles.cardTitle, { color: theme.text }]}>{content.title}</Text>
      {content.detail ? <Text numberOfLines={2} style={{ color: theme.muted }}>{content.detail}</Text> : null}
    </Pressable>
  );
}

function TypingLine({ channelId }: { channelId: Id }) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const names = Object.entries(workspace.typing[channelId] ?? {})
    .filter(([memberId, at]) => memberId !== workspace.bootstrap?.me.id && Date.now() - at < 4_000)
    .map(([memberId]) => workspace.bootstrap?.members.find((member) => member.id === memberId)?.display_name)
    .filter(Boolean);
  const runs = workspace.bootstrap?.active_runs.filter((run) => run.channel_id === channelId) ?? [];
  const label = names.length ? `${names.join(", ")} typing…` : runs.length ? `${runs.length === 1 ? "An agent is" : `${runs.length} agents are`} working…` : "";
  return label ? <Text style={[styles.typing, { color: theme.muted }]}>{label}</Text> : null;
}

const styles = StyleSheet.create({
  conversation: { flex: 1 },
  list: { paddingVertical: 12 },
  emptyList: { flexGrow: 1, justifyContent: "center" },
  day: { alignItems: "center", paddingVertical: 10 },
  dayText: { fontSize: 12, fontWeight: "600", borderRadius: 999, paddingHorizontal: 10, paddingVertical: 3, overflow: "hidden" },
  message: { flexDirection: "row", gap: 10, paddingHorizontal: 14, paddingVertical: 8 },
  messageMain: { flex: 1, minWidth: 0 },
  messageHead: { flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 6, marginBottom: 2 },
  author: { fontSize: 15, fontWeight: "700" },
  time: { fontSize: 11 },
  activity: { flexDirection: "row", gap: 8, paddingHorizontal: 20, paddingVertical: 7 },
  activityText: { flex: 1, fontSize: 13, lineHeight: 18 },
  reactionRow: { flexDirection: "row", flexWrap: "wrap", gap: 5, marginTop: 6 },
  reaction: { minHeight: 32, justifyContent: "center", borderRadius: 999, paddingHorizontal: 10, paddingVertical: 5 },
  messageActions: { flexDirection: "row", gap: 18, marginTop: 2 },
  messageAction: { minHeight: 32, justifyContent: "center" },
  emojiGrid: { flexDirection: "row", flexWrap: "wrap", padding: 18, justifyContent: "center" },
  emoji: { width: 64, height: 58, alignItems: "center", justifyContent: "center" },
  runLine: { flexDirection: "row", gap: 8, alignItems: "center", minHeight: 38, borderRadius: 9, paddingHorizontal: 10, marginVertical: 5 },
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 11, padding: 12, gap: 3, marginTop: 7 },
  cardTitle: { fontWeight: "700", fontSize: 15 },
  typing: { fontSize: 12, paddingHorizontal: 16, paddingVertical: 4 },
});
