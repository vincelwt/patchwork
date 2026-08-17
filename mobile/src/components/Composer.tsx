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

import { outboxFor } from "@client/mobile-store-reducer";
import { beginSend } from "@client/send";
import type { Id, Message } from "@client/types";
import { composerKey } from "@/lib/composer";
import { useDictation } from "@/lib/dictation";
import { useKeyboardInset } from "@/lib/keyboard";
import { useLayout } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { PendingImages, useImageAttachments } from "./Attachment";
import { Button, Glass, Icon, Measured } from "./ui";

interface ComposerProps {
  channelId: Id;
  parentId?: Id;
  taskId?: Id;
  placeholder?: string;
  replyTo?: Message;
  onCancelReply?: () => void;
}

export function Composer(props: ComposerProps) {
  const draftKey = composerKey(props.channelId, props.parentId);
  // Sending, uploads and errors are transient state for this conversation only.
  return <ComposerBox key={draftKey} draftKey={draftKey} {...props} />;
}

function ComposerBox({
  channelId,
  parentId,
  taskId,
  placeholder = "Message the workspace",
  replyTo,
  onCancelReply,
  draftKey,
}: ComposerProps & { draftKey: string }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const keyboard = useKeyboardInset(insets.bottom);
  const { gutter } = useLayout();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const text = workspace.drafts[draftKey] ?? "";
  const images = useImageAttachments(taskId);
  const [busy, setBusy] = useState(false);
  const sendLock = useRef(false);
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
  const empty = !text.trim() && images.pending.length === 0;
  // Only this conversation's unsent messages: a thread and its channel each
  // report their own.
  const queued = outboxFor(workspace, channelId, parentId);
  const failed = queued.find((entry) => entry.status === "failed");
  const pending = queued.filter((entry) => entry.status !== "failed");
  const waiting = pending.length;
  const saving = pending.some((entry) => entry.status === "saving");
  const sending = pending.some((entry) => entry.status === "sending");

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

  /// The draft is only cleared once the message is durably queued, so a send
  /// that cannot leave the phone yet still leaves the composer.
  const send = async () => {
    if (empty || !images.ready || !beginSend(sendLock)) return;
    setBusy(true);
    setError("");
    try {
      await store.queueMessage({
        channelId,
        parentId,
        replyToId: replyTo?.id,
        body: text.trim(),
        attachmentIds: images.attachmentIds,
      });
      if (store.getSnapshot().drafts[draftKey] === text) {
        store.setDraft(draftKey, "");
      }
      images.clear(images.attachmentIds);
      onCancelReply?.();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      sendLock.current = false;
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
        <View style={[styles.composer, { backgroundColor: theme.input, borderColor: theme.line }]}>
          {/* Inside the capsule, so what is attached reads as part of what is
              being written rather than as a strip floating above it. */}
          <PendingImages images={images.pending} onRemove={images.remove} />
          <TextInput
            ref={input}
            accessibilityLabel={placeholder}
            multiline
            maxLength={32_000}
            placeholder={placeholder}
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
              disabled={empty || busy || !images.ready}
              onPress={() => void send()}
              style={({ pressed }) => [
                styles.send,
                { backgroundColor: theme.accent },
                pressed && { opacity: 0.65 },
                (empty || busy || !images.ready) && { opacity: 0.35 },
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
        {/* What has happened to what was already sent, in one line under the
            capsule: waiting to go out, or refused and needing a decision. */}
        {failed || waiting ? (
          <View accessibilityLiveRegion="polite" style={styles.status}>
            <Text
              numberOfLines={2}
              style={[styles.statusText, { color: failed ? theme.danger : theme.muted }]}
            >
              {failed
                ? `Not sent: ${failed.error || "the workspace refused this message"}`
                : saving
                  ? "Saving message…"
                  : workspace.connection === "live"
                    ? sending
                      ? `Sending ${waiting === 1 ? "message" : `${waiting} messages`}…`
                      : `${waiting === 1 ? "Message queued" : `${waiting} messages queued`} · retrying automatically`
                    : `${waiting === 1 ? "1 message" : `${waiting} messages`} will send when you reconnect`}
            </Text>
            {failed ? (
              <>
                <Button label="Retry" compact tone="quiet" onPress={() => store.retryQueuedMessage(failed.id)} />
                <Button label="Remove" compact tone="quiet" onPress={() => store.removeQueuedMessage(failed.id)} />
              </>
            ) : null}
          </View>
        ) : null}
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
  status: { flexDirection: "row", alignItems: "center", gap: 6, minHeight: 30, marginTop: 3, paddingHorizontal: 4 },
  statusText: { flex: 1, fontSize: 12 },
  error: { fontSize: 12, marginTop: 5, paddingHorizontal: 4 },
});
