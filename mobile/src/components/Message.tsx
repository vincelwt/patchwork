import { memo, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Linking,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useRouter } from "expo-router";

import type { Id, Message, MessageCard, Run } from "@client/types";
import { dayLabel, isSameTurn, runStatusLabel, timeOfDay } from "@/lib/format";
import { followNewest, useLayout } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { AttachmentView } from "./Attachment";
import { ChartCard } from "./Chart";
import { Composer } from "./Composer";
import { useGrantedOpen } from "./Evidence";
import { Markdown } from "./Markdown";
import { Avatar, Badge, Button, Empty, ErrorNotice, Icon, Measured, Sheet } from "./ui";

const EMOJI = ["👍", "❤️", "🎉", "👀", "✅", "🤔", "🙏", "🚀"];

export function Conversation({ channelId }: { channelId: Id }) {
  const theme = useTheme();
  const { gutter } = useLayout();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const list = useRef<FlatList<Message>>(null);
  const channel = workspace.bootstrap?.channels.find((item) => item.id === channelId);
  const messages = workspace.messages[channelId] ?? [];
  const [replyTo, setReplyTo] = useState<Message>();
  // Newest first, drawn upside down. The newest message then lives at offset
  // zero, so the transcript opens on it rather than being scrolled there once
  // it has laid out, and older messages load in without moving the view. The
  // oldest end is the list's footer, which is where loading more belongs.
  const newestFirst = useMemo(() => [...messages].reverse(), [messages]);

  useEffect(() => {
    setReplyTo(undefined);
    void store.loadMessages(channelId);
    return store.onMessageSent(channelId, undefined, () =>
      requestAnimationFrame(() =>
        list.current?.scrollToOffset({ offset: 0, animated: true }),
      ),
    );
  }, [channelId, store]);

  if (!channel) return <Empty title="Conversation unavailable" detail="It may have been archived or removed." />;

  return (
    <View style={styles.conversation}>
      <FlatList
        ref={list}
        inverted
        data={newestFirst}
        keyExtractor={(message) => message.id}
        contentContainerStyle={newestFirst.length ? styles.list : styles.emptyList}
        renderItem={({ item, index }) => {
          // Upside down, so the message before this one in time is the next one
          // along in the data.
          const previous = newestFirst[index + 1];
          const newDay = !previous || dayLabel(previous.created_at) !== dayLabel(item.created_at);
          return (
            <Measured>
              {newDay ? (
                <View style={styles.day}>
                  <Text style={[styles.dayText, { color: theme.muted, backgroundColor: theme.surface }]}>{dayLabel(item.created_at)}</Text>
                </View>
              ) : null}
              <MessageRow message={item} compact={!newDay && isSameTurn(previous, item)} onReply={setReplyTo} />
            </Measured>
          );
        }}
        ListEmptyComponent={<Empty title="Nothing here yet" detail="Say something or mention an agent with @." />}
        ListFooterComponent={workspace.hasMore[channelId] ? (
          <Measured>
            <View style={{ paddingHorizontal: gutter, paddingVertical: 8 }}>
              <Button
                label="Load older messages"
                tone="quiet"
                onPress={() => void store.loadMessages(channelId, messages[0]?.id)}
              />
            </View>
          </Measured>
        ) : null}
        maintainVisibleContentPosition={followNewest}
        keyboardDismissMode="interactive"
        initialNumToRender={20}
        windowSize={9}
      />
      <TypingLine channelId={channelId} />
      <Composer
        channelId={channelId}
        taskId={channel.task_id}
        replyTo={replyTo}
        onCancelReply={() => setReplyTo(undefined)}
      />
    </View>
  );
}

export const MessageRow = memo(function MessageRow({
  message,
  inThread,
  compact,
  onReply,
}: {
  message: Message;
  inThread?: boolean;
  /// Part of the same turn as the line above: no face, no name, no time.
  compact?: boolean;
  onReply?: (message: Message) => void;
}) {
  const theme = useTheme();
  const router = useRouter();
  const { gutter } = useLayout();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const [actions, setActions] = useState(false);
  const [queueing, setQueueing] = useState(false);
  const author = workspace.bootstrap?.members.find((member) => member.id === message.author_id);
  const replyTo = message.reply_to_id
    ? workspace.messages[message.channel_id]?.find((item) => item.id === message.reply_to_id)
    : undefined;
  const repliedMessage = replyTo ?? message.reply_to;
  const replyAuthor = repliedMessage
    ? workspace.bootstrap?.members.find((member) => member.id === repliedMessage.author_id)
    : undefined;
  const run = message.run_id
    ? workspace.runDetails[message.run_id]?.run ?? workspace.bootstrap?.active_runs.find((item) => item.id === message.run_id)
    : undefined;

  const react = async (emoji: string) => {
    setActions(false);
    await store.mutate((api) => api.react(message.id, emoji), false);
  };

  /// A suggested next step is said in your own words and in the place it was
  /// offered: inside its thread, or quoting the message it came from. Queued
  /// like any other send, so it survives having no signal.
  const say = async (suggestion: string) => {
    if (queueing) return;
    setQueueing(true);
    try {
      await store.queueMessage({
        channelId: message.channel_id,
        parentId: message.parent_id,
        replyToId: message.parent_id ? undefined : message.id,
        body: suggestion,
        attachmentIds: [],
      });
    } finally {
      setQueueing(false);
    }
  };

  if (message.kind === "status" || message.kind === "system") {
    return (
      <View style={[styles.activity, { paddingHorizontal: gutter + 6 }]}>
        <Text style={{ color: theme.faint }}>•</Text>
        <Text style={[styles.activityText, { color: theme.muted }]}>{message.body}</Text>
      </View>
    );
  }

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`${author?.display_name ?? "Unknown"}. ${message.body}`}
      accessibilityHint="Press and hold for reactions, reply, and thread"
      accessibilityActions={[
        { name: "react", label: "React" },
        ...(onReply ? [{ name: "reply", label: "Reply" }] : []),
        ...(inThread ? [] : [{ name: "thread", label: "Open thread" }]),
      ]}
      onAccessibilityAction={({ nativeEvent }) => {
        if (nativeEvent.actionName === "reply") return onReply?.(message);
        if (nativeEvent.actionName === "thread") {
          return router.push({ pathname: "/(app)/threads/[messageId]", params: { messageId: message.id } });
        }
        setActions(true);
      }}
      delayLongPress={280}
      onLongPress={() => setActions(true)}
      style={[styles.message, compact && styles.messageTight, { paddingHorizontal: gutter }]}
    >
      {compact ? <View style={styles.avatarSpacer} /> : <Avatar member={author} size={32} />}
      <View style={styles.messageMain}>
        {compact ? null : (
          <View style={styles.messageHead}>
            <Text style={[styles.author, { color: theme.text }]}>{author?.display_name ?? "Unknown"}</Text>
            {author?.kind === "agent" ? <Badge tone="accent">agent</Badge> : null}
            <Text style={[styles.time, { color: theme.faint }]}>{timeOfDay(message.created_at)}</Text>
          </View>
        )}
        {run ? <RunLine run={run} /> : null}
        {message.reply_to_id ? (
          <View style={styles.replyReference}>
            <Text style={{ color: theme.faint }}>↩</Text>
            <Text style={[styles.replyAuthor, { color: theme.muted }]}>
              {repliedMessage ? replyAuthor?.display_name ?? "Unknown" : "Earlier message"}
            </Text>
            {repliedMessage ? (
              <Text numberOfLines={1} style={[styles.replyPreview, { color: theme.faint }]}>
                {repliedMessage.body.trim() ||
                  (repliedMessage.card
                    ? repliedMessage.card.type.replaceAll("_", " ")
                    : "Attachment")}
              </Text>
            ) : null}
          </View>
        ) : null}
        {message.body ? <Markdown body={message.body} /> : null}
        {message.card ? <CardView card={message.card} /> : null}
        {message.attachments.map((attachment) => <AttachmentView key={attachment.id} attachment={attachment} />)}
        {message.suggestions?.length ? (
          <View style={styles.suggestionRow}>
            {message.suggestions.map((suggestion) => (
              <Pressable
                key={suggestion}
                accessibilityRole="button"
                accessibilityLabel={`Send suggestion: ${suggestion}`}
                accessibilityState={{ disabled: queueing, busy: queueing }}
                // One press, one message: pressing again while the first is
                // still queueing would say the same thing twice.
                disabled={queueing}
                onPress={() => void say(suggestion)}
                style={[styles.suggestion, { backgroundColor: theme.surface, borderColor: theme.line, opacity: queueing ? 0.55 : 1 }]}
              >
                <Text style={[styles.suggestionText, { color: theme.text }]}>{suggestion}</Text>
              </Pressable>
            ))}
          </View>
        ) : null}
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
        {/* Only a thread that exists earns a line of its own; everything else
            lives behind a press and hold, so the transcript stays readable. */}
        {!inThread && message.reply_count ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Open thread"
            onPress={() => router.push({ pathname: "/(app)/threads/[messageId]", params: { messageId: message.id } })}
            hitSlop={6}
            style={styles.threadLine}
          >
            <Text style={[styles.actionLabel, { color: theme.accent }]}>
              {`${message.reply_count} ${message.reply_count === 1 ? "reply" : "replies"}`}
            </Text>
          </Pressable>
        ) : null}
      </View>
      <Sheet visible={actions} title="Message" onClose={() => setActions(false)}>
        <View style={styles.emojiGrid}>
          {EMOJI.map((emoji) => (
            <Pressable key={emoji} accessibilityRole="button" accessibilityLabel={`React ${emoji}`} onPress={() => void react(emoji)} style={styles.emoji}>
              <Text style={{ fontSize: 28 }}>{emoji}</Text>
            </Pressable>
          ))}
        </View>
        <View style={styles.sheetActions}>
          {onReply ? (
            <Button
              label="Reply"
              tone="secondary"
              onPress={() => {
                setActions(false);
                onReply(message);
              }}
            />
          ) : null}
          {!inThread ? (
            <Button
              label={message.reply_count ? "Open thread" : "Reply in thread"}
              tone="secondary"
              onPress={() => {
                setActions(false);
                router.push({ pathname: "/(app)/threads/[messageId]", params: { messageId: message.id } });
              }}
            />
          ) : null}
        </View>
      </Sheet>
    </Pressable>
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
  const { open, busy, error } = useGrantedOpen();
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
        return { title: card.caption || "Artifact", detail: "Open the file", press: () => void open((api) => api.grantFile(card.attachment_id)) };
      case "preview": {
        const preview = workspace.bootstrap?.previews.find((item) => item.id === card.preview_id);
        const live = preview?.status === "live";
        return {
          title: preview?.label || "Preview",
          detail: live ? "Open the running site" : preview ? `Preview is ${preview.status}` : "Preview unavailable",
          press: live ? (() => { void open((api) => api.grantPreview(card.preview_id)); }) : undefined,
        };
      }
      case "chart":
        return { title: "Chart", detail: card.caption, press: undefined };
    }
  }, [card, open, router, workspace.bootstrap?.tasks]);
  // Drawn from its spec rather than announced, so the numbers are on screen.
  if (card.type === "chart") return <ChartCard spec={card.spec} caption={card.caption} />;
  return (
    <>
      <Pressable
        accessibilityRole={content.press ? "button" : undefined}
        accessibilityState={{ busy }}
        disabled={!content.press || busy}
        onPress={content.press}
        style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }]}
      >
        <Text style={[styles.cardTitle, { color: theme.text }]}>{content.title}</Text>
        {content.detail ? <Text numberOfLines={2} style={{ color: theme.muted }}>{busy ? "Opening…" : content.detail}</Text> : null}
      </Pressable>
      <ErrorNotice message={error} />
    </>
  );
}

function TypingLine({ channelId }: { channelId: Id }) {
  const theme = useTheme();
  const { gutter } = useLayout();
  const workspace = useWorkspace();
  const names = Object.entries(workspace.typing[channelId] ?? {})
    .filter(([memberId, at]) => memberId !== workspace.bootstrap?.me.id && Date.now() - at < 4_000)
    .map(([memberId]) => workspace.bootstrap?.members.find((member) => member.id === memberId)?.display_name)
    .filter(Boolean);
  const runs = workspace.bootstrap?.active_runs.filter((run) => run.channel_id === channelId) ?? [];
  const label = names.length ? `${names.join(", ")} typing…` : runs.length ? `${runs.length === 1 ? "An agent is" : `${runs.length} agents are`} working…` : "";
  return label ? (
    <Text style={[styles.typing, { color: theme.muted, paddingHorizontal: gutter }]}>{label}</Text>
  ) : null;
}

const styles = StyleSheet.create({
  conversation: { flex: 1 },
  list: { paddingVertical: 12 },
  emptyList: { flexGrow: 1, justifyContent: "center" },
  day: { alignItems: "center", paddingVertical: 10 },
  dayText: { fontSize: 12, fontWeight: "600", borderRadius: 999, paddingHorizontal: 10, paddingVertical: 3, overflow: "hidden" },
  message: { flexDirection: "row", gap: 11, paddingVertical: 9 },
  messageTight: { paddingTop: 0, paddingBottom: 3 },
  avatarSpacer: { width: 32 },
  messageMain: { flex: 1, minWidth: 0 },
  messageHead: { flexDirection: "row", alignItems: "center", flexWrap: "wrap", gap: 6, marginBottom: 2 },
  author: { fontSize: 15, fontWeight: "700" },
  time: { fontSize: 11 },
  activity: { flexDirection: "row", gap: 8, paddingVertical: 7 },
  activityText: { flex: 1, fontSize: 13, lineHeight: 18 },
  replyReference: { flexDirection: "row", alignItems: "center", gap: 5, minWidth: 0, marginBottom: 3 },
  replyAuthor: { fontSize: 12, fontWeight: "600" },
  replyPreview: { flex: 1, fontSize: 12 },
  suggestionRow: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginTop: 7 },
  suggestion: { minHeight: 34, justifyContent: "center", borderWidth: StyleSheet.hairlineWidth, borderRadius: 999, paddingHorizontal: 12, paddingVertical: 6 },
  suggestionText: { fontSize: 13, fontWeight: "600" },
  reactionRow: { flexDirection: "row", flexWrap: "wrap", gap: 5, marginTop: 6 },
  reaction: { minHeight: 32, justifyContent: "center", borderRadius: 999, paddingHorizontal: 10, paddingVertical: 5 },
  threadLine: { minHeight: 28, justifyContent: "center", marginTop: 1 },
  actionLabel: { fontSize: 13, fontWeight: "600" },
  sheetActions: { paddingHorizontal: 18, paddingBottom: 20, gap: 10 },
  emojiGrid: { flexDirection: "row", flexWrap: "wrap", padding: 18, justifyContent: "center" },
  emoji: { width: 64, height: 58, alignItems: "center", justifyContent: "center" },
  runLine: { flexDirection: "row", gap: 8, alignItems: "center", minHeight: 38, borderRadius: 9, paddingHorizontal: 10, marginVertical: 5 },
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 11, padding: 12, gap: 3, marginTop: 7 },
  cardTitle: { fontWeight: "700", fontSize: 15 },
  typing: { fontSize: 12, paddingVertical: 4 },
});
