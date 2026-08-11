import { useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";

import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { Id, Message } from "@client/types";
import { useDictation } from "@/lib/dictation";
import { useKeyboardInset } from "@/lib/keyboard";
import { useLayout } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { PendingImages, useImageAttachments } from "./Attachment";
import { Glass, Icon, Measured } from "./ui";

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
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardInset(insets.bottom);
  const { gutter } = useLayout();
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
  const mention = useMemo(() => {
    const match = text.match(/(?:^|\s)@([\w-]*)$/);
    if (!match) return [];
    const query = match[1].toLowerCase();
    return members
      .filter((member) => member.handle.toLowerCase().startsWith(query))
      .slice(0, 5);
  }, [members, text]);
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

  const insertMention = (handle: string) => {
    change(text.replace(/@[\w-]*$/, `@${handle} `));
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
    // The bar floats as a capsule over the conversation rather than sealing the
    // bottom of the screen with a rule, and sits on the keyboard while one is
    // open instead of underneath it.
    <View
      style={[
        styles.wrap,
        { backgroundColor: theme.bg, paddingHorizontal: gutter, paddingBottom: 10 + insets.bottom + keyboard },
      ]}
    >
     <Measured>
      {mention.length ? (
          <Glass radius={14} style={styles.mentions}>
            {mention.map((member) => (
              <Pressable accessibilityRole="button" key={member.id} onPress={() => insertMention(member.handle)} style={styles.mentionRow}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{member.display_name}</Text>
                <Text style={{ color: theme.muted }}>@{member.handle}</Text>
              </Pressable>
            ))}
          </Glass>
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
              <Icon name={{ ios: "photo.badge.plus", android: "add_photo_alternate", web: "add_photo_alternate" }} color={theme.accent} size={22} />
            </Pressable>
            {dictation.supported ? (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={dictation.recording ? "Stop dictating" : "Dictate"}
                onPress={() => (dictation.recording ? dictation.stop() : void dictation.start(text))}
                style={[styles.iconButton, dictation.recording && { backgroundColor: theme.dangerSoft }]}
              >
                <Icon
                  name={dictation.recording
                    ? { ios: "stop.fill", android: "stop", web: "stop" }
                    : { ios: "mic.fill", android: "mic", web: "mic" }}
                  color={dictation.recording ? theme.danger : theme.accent}
                  size={20}
                />
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
                <Icon name={{ ios: "arrow.up", android: "arrow_upward", web: "arrow_upward" }} color={theme.onAccent} size={19} />
              )}
            </Pressable>
          </View>
        </View>
        {error || images.error || dictation.error ? (
          <Text style={[styles.error, { color: theme.danger }]}>{error || images.error || dictation.error}</Text>
        ) : null}
     </Measured>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { paddingTop: 10 },
  mentions: { marginBottom: 6, overflow: "hidden" },
  mentionRow: { minHeight: 44, paddingHorizontal: 12, flexDirection: "row", alignItems: "center", gap: 8 },
  reply: { flexDirection: "row", alignItems: "center", gap: 6, minHeight: 32, paddingHorizontal: 4 },
  replyLabel: { fontSize: 12, fontWeight: "600" },
  replyPreview: { flex: 1, fontSize: 12 },
  replyClose: { width: 28, height: 28, alignItems: "center", justifyContent: "center" },
  composer: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 24, paddingHorizontal: 10, paddingVertical: 9 },
  input: { minHeight: 38, maxHeight: 150, fontSize: 16, lineHeight: 22, paddingHorizontal: 8, paddingTop: 4, textAlignVertical: "top" },
  actions: { flexDirection: "row", alignItems: "center", marginTop: 4, gap: 4 },
  iconButton: { width: 40, height: 40, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  send: { width: 40, height: 40, borderRadius: 20, alignItems: "center", justifyContent: "center" },
  error: { fontSize: 12, marginTop: 5, paddingHorizontal: 4 },
});
