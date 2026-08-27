import { useMemo, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";

import type { Ask, Attachment, Id } from "@client/types";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { AttachmentView } from "./Attachment";
import { Button, ErrorNotice, TextField } from "./ui";

/// The one thing an agent needs from a person, wherever it is met: a home row,
/// a task header, a transcript, a run. Every path out of it is `answerAsk`, so
/// answering on the phone is one tap rather than a screen of its own.
export function AskCard({ ask }: { ask: Ask }) {
  const theme = useTheme();
  const store = useWorkspaceStore();
  const evidence = usePinnedEvidence(ask.evidence_ids);
  const [chosen, setChosen] = useState<string[]>([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const send = async (answer: string[]) => {
    setBusy(true);
    setError("");
    try {
      await store.mutate((api) => api.answerAsk(ask.id, answer, note.trim()));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
      setBusy(false);
    }
  };

  const choose = (label: string) => {
    // One choice is the answer, so pressing it is the whole interaction.
    if (!ask.multi_select) return void send([label]);
    setChosen((current) =>
      current.includes(label) ? current.filter((item) => item !== label) : [...current, label],
    );
  };

  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }]}>
      <Text style={[styles.text, { color: theme.text }]}>{ask.text}</Text>
      {ask.summary.map((line) => (
        <View key={line} style={styles.bullet}>
          <Text style={{ color: theme.faint }}>•</Text>
          <Text style={[styles.bulletText, { color: theme.muted }]}>{line}</Text>
        </View>
      ))}
      {evidence.map((attachment) => (
        <AttachmentView key={attachment.id} attachment={attachment} />
      ))}
      {ask.options.map((option) => {
        const selected = chosen.includes(option.label);
        return (
          <Pressable
            accessibilityRole={ask.multi_select ? "checkbox" : "button"}
            accessibilityState={{ checked: selected, disabled: busy }}
            key={option.label}
            disabled={busy}
            onPress={() => choose(option.label)}
            style={({ pressed }) => [
              styles.option,
              { borderColor: selected ? theme.accent : theme.line, backgroundColor: selected ? theme.accentSoft : theme.raised },
              pressed && styles.pressed,
            ]}
          >
            <Text style={[styles.optionLabel, { color: selected ? theme.accent : theme.text }]}>{option.label}</Text>
            {option.description ? (
              <Text style={[styles.optionDetail, { color: theme.muted }]}>{option.description}</Text>
            ) : null}
          </Pressable>
        );
      })}
      {ask.allow_free_text ? (
        <TextField
          multiline
          value={note}
          onChangeText={setNote}
          placeholder="Answer in your own words"
        />
      ) : null}
      {/* Recording the action label is the approval, so the button that says it
          is also the one that sends it. */}
      {ask.action ? <Button label={ask.action} busy={busy} onPress={() => void send([ask.action!])} /> : null}
      {ask.multi_select || ask.allow_free_text ? (
        <Button
          label="Send answer"
          tone={ask.action ? "secondary" : "primary"}
          busy={busy}
          disabled={!chosen.length && !note.trim()}
          onPress={() => void send(chosen)}
        />
      ) : null}
      <ErrorNotice message={error} />
    </View>
  );
}

/// What the ask says to look at first. Read out of the conversation it was
/// pinned from, because that is where it was posted and the phone has it.
///
/// ponytail: evidence posted to a conversation this device has not opened will
/// not resolve. Fetch the task detail here the day that shows.
function usePinnedEvidence(ids: Id[]): Attachment[] {
  const workspace = useWorkspace();
  return useMemo(() => {
    if (!ids.length) return [];
    const found = new Map<Id, Attachment>();
    for (const messages of [
      ...Object.values(workspace.messages),
      ...Object.values(workspace.threads),
    ]) {
      for (const message of messages) {
        for (const attachment of message.attachments) {
          if (ids.includes(attachment.id)) found.set(attachment.id, attachment);
        }
      }
    }
    return ids.flatMap((id) => {
      const attachment = found.get(id);
      return attachment ? [attachment] : [];
    });
  }, [ids, workspace.messages, workspace.threads]);
}

const styles = StyleSheet.create({
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 13, padding: 13, gap: 9, marginTop: 7 },
  text: { fontSize: 16, fontWeight: "700", lineHeight: 22 },
  bullet: { flexDirection: "row", gap: 7 },
  bulletText: { flex: 1, fontSize: 14, lineHeight: 19 },
  option: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 11, padding: 12, gap: 3 },
  optionLabel: { fontSize: 15, fontWeight: "700" },
  optionDetail: { fontSize: 14, lineHeight: 19 },
  pressed: { opacity: 0.6 },
});
