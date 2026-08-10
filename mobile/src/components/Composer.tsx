import { useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { matchTasks } from "@client/mentions";
import type { Id, Message } from "@client/types";
import { useDictation } from "@/lib/dictation";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { PendingImages, useImageAttachments } from "./Attachment";

export function Composer({
  channelId,
  parentId,
  taskId,
  placeholder = "Message the workspace",
  replyTo,
  onCancelReply,
}: {
  channelId: Id;
  parentId?: Id;
  taskId?: Id;
  placeholder?: string;
  replyTo?: Message;
  onCancelReply?: () => void;
}) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const draftKey = parentId ? `thread:${parentId}` : channelId;
  const text = workspace.drafts[draftKey] ?? "";
  const images = useImageAttachments(taskId);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const typingAt = useRef(0);
  const input = useRef<TextInput>(null);
  const members = workspace.bootstrap?.members ?? [];
  const tasks = workspace.bootstrap?.tasks ?? [];
  // `@` brings a teammate in, `#` points at a task. A task mention is its key,
  // the same reference every other surface writes.
  const mention = useMemo(() => {
    const match = text.match(/(?:^|\s)([@#])([\w-]*)$/);
    if (!match) return [];
    const query = match[2].toLowerCase();
    if (match[1] === "#")
      return matchTasks(tasks, query, 5).map((task) => ({
        id: task.id,
        insert: `${task.key} `,
        name: task.title,
        sub: task.key,
      }));
    return members
      .filter((member) => member.handle.toLowerCase().startsWith(query))
      .slice(0, 5)
      .map((member) => ({
        id: member.id,
        insert: `@${member.handle} `,
        name: member.display_name,
        sub: `@${member.handle}`,
      }));
  }, [members, tasks, text]);
  const dictation = useDictation((value) => store.setDraft(draftKey, value));
  const offline = workspace.connection !== "live";
  const empty = !text.trim() && images.pending.length === 0;

  useEffect(() => {
    if (replyTo) input.current?.focus();
  }, [replyTo?.id]);

  const change = (value: string) => {
    store.setDraft(draftKey, value);
    const now = Date.now();
    if (now - typingAt.current > 2_000) {
      typingAt.current = now;
      store.sendTyping(channelId);
    }
  };

  const insertMention = (insert: string) => {
    change(text.replace(/[@#][\w-]*$/, insert));
  };

  const send = async () => {
    if (empty || busy || images.uploading || offline) return;
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) =>
          api.send(channelId, {
            body: text.trim(),
            parent_id: parentId,
            reply_to_id: replyTo?.id,
            attachment_ids: images.pending.map((item) => item.attachment.id),
          }),
        false,
      );
      store.setDraft(draftKey, "");
      images.clear();
      onCancelReply?.();
      if (parentId) await store.loadThread(parentId);
      else await store.loadMessages(channelId);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  return (
    <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined}>
      <View style={[styles.wrap, { backgroundColor: theme.bg, borderTopColor: theme.line }]}>
        {mention.length ? (
          <View style={[styles.mentions, { backgroundColor: theme.raised, borderColor: theme.line }]}>
            {mention.map((candidate) => (
              <Pressable accessibilityRole="button" key={candidate.id} onPress={() => insertMention(candidate.insert)} style={styles.mentionRow}>
                <Text numberOfLines={1} style={{ color: theme.text, flexShrink: 1, fontWeight: "600" }}>{candidate.name}</Text>
                <Text style={{ color: theme.muted }}>{candidate.sub}</Text>
              </Pressable>
            ))}
          </View>
        ) : null}
        {replyTo ? (
          <View style={styles.reply}>
            <Text style={[styles.replyLabel, { color: theme.muted }]}>
              Replying to{" "}
              {members.find((member) => member.id === replyTo.author_id)?.display_name ??
                "Unknown"}
            </Text>
            <Text numberOfLines={1} style={[styles.replyPreview, { color: theme.faint }]}>
              {replyTo.body.trim() ||
                (replyTo.card ? replyTo.card.type.replaceAll("_", " ") : "Attachment")}
            </Text>
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Cancel reply"
              onPress={onCancelReply}
              hitSlop={8}
              style={styles.replyClose}
            >
              <Text style={{ color: theme.muted, fontSize: 20 }}>×</Text>
            </Pressable>
          </View>
        ) : null}
        <PendingImages images={images.pending} onRemove={images.remove} />
        <View style={[styles.composer, { backgroundColor: theme.input, borderColor: theme.line }]}>
          <TextInput
            ref={input}
            accessibilityLabel={placeholder}
            multiline
            maxLength={32_000}
            placeholder={offline ? "Reconnect to send" : placeholder}
            placeholderTextColor={theme.faint}
            value={text}
            onChangeText={change}
            style={[styles.input, { color: theme.text }]}
          />
          <View style={styles.actions}>
            <Pressable accessibilityRole="button" accessibilityLabel="Attach image" onPress={() => void images.pick()} style={styles.iconButton}>
              <Text style={[styles.icon, { color: theme.accent }]}>＋</Text>
            </Pressable>
            {dictation.supported ? (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={dictation.recording ? "Stop dictating" : "Dictate"}
                onPress={() => (dictation.recording ? dictation.stop() : void dictation.start(text))}
                style={[styles.iconButton, dictation.recording && { backgroundColor: theme.dangerSoft }]}
              >
                <Text style={[styles.mic, { color: dictation.recording ? theme.danger : theme.accent }]}>●</Text>
              </Pressable>
            ) : null}
            <View style={{ flex: 1 }} />
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Send"
              disabled={empty || busy || images.uploading || offline}
              onPress={() => void send()}
              style={({ pressed }) => [
                styles.send,
                { backgroundColor: theme.accent },
                pressed && { opacity: 0.65 },
                (empty || busy || images.uploading || offline) && { opacity: 0.35 },
              ]}
            >
              {busy || images.uploading ? (
                <ActivityIndicator size="small" color={theme.onAccent} />
              ) : (
                <Text style={{ color: theme.onAccent, fontSize: 18, fontWeight: "800" }}>↑</Text>
              )}
            </Pressable>
          </View>
        </View>
        {error || images.error || dictation.error ? (
          <Text style={[styles.error, { color: theme.danger }]}>{error || images.error || dictation.error}</Text>
        ) : null}
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  wrap: { borderTopWidth: StyleSheet.hairlineWidth, paddingHorizontal: 12, paddingTop: 8, paddingBottom: 8 },
  mentions: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 10, marginBottom: 6, overflow: "hidden" },
  mentionRow: { minHeight: 44, paddingHorizontal: 12, flexDirection: "row", alignItems: "center", gap: 8 },
  reply: { flexDirection: "row", alignItems: "center", gap: 6, minHeight: 32, paddingHorizontal: 4 },
  replyLabel: { fontSize: 12, fontWeight: "600" },
  replyPreview: { flex: 1, fontSize: 12 },
  replyClose: { width: 28, height: 28, alignItems: "center", justifyContent: "center" },
  composer: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 14, padding: 8 },
  input: { minHeight: 38, maxHeight: 150, fontSize: 16, lineHeight: 22, paddingHorizontal: 4, paddingTop: 4, textAlignVertical: "top" },
  actions: { flexDirection: "row", alignItems: "center", marginTop: 4, gap: 4 },
  iconButton: { width: 40, height: 40, borderRadius: 10, alignItems: "center", justifyContent: "center" },
  icon: { fontSize: 26, lineHeight: 28, fontWeight: "400" },
  mic: { fontSize: 17 },
  send: { width: 40, height: 40, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  error: { fontSize: 12, marginTop: 5, paddingHorizontal: 4 },
});
