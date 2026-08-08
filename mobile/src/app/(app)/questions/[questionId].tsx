import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";

import type { QuestionAnswer } from "@client/types";
import { Button, Card, ErrorNotice, PageHeader, ScrollScreen, TextField } from "@/components/ui";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function QuestionScreen() {
  const { questionId } = useLocalSearchParams<{ questionId: string }>();
  const router = useRouter();
  const theme = useTheme();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const question = workspace.bootstrap?.open_questions.find((item) => item.id === questionId)
    ?? Object.values(workspace.runDetails).flatMap((detail) => detail.questions).find((item) => item.id === questionId);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  if (!question) {
    return <View style={{ flex: 1 }}><PageHeader title="Question" back /><Text style={{ color: theme.muted, padding: 20 }}>This question was already answered or cancelled.</Text></View>;
  }

  const toggle = (itemId: string, value: string, multi: boolean) => {
    setAnswers((current) => {
      const selected = current[itemId] ?? [];
      return {
        ...current,
        [itemId]: multi
          ? selected.includes(value)
            ? selected.filter((item) => item !== value)
            : [...selected, value]
          : [value],
      };
    });
  };

  const submit = async () => {
    const payload: QuestionAnswer[] = question.items.map((item) => ({
      item_id: item.id,
      values: answers[item.id] ?? [],
      note: notes[item.id]?.trim() ?? "",
    }));
    const missing = question.items.find((item) => !payload.find((answer) => answer.item_id === item.id)?.values.length && !notes[item.id]?.trim());
    if (missing) {
      setError(`Answer “${missing.header}” before sending.`);
      return;
    }
    setBusy(true);
    try {
      await store.mutate((api) => api.answerQuestion(question.id, payload));
      router.back();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={{ flex: 1 }}>
      <PageHeader title={question.headline || "Agent question"} back />
      <ScrollScreen>
        {question.items.map((item) => (
          <Card key={item.id} style={styles.card}>
            <Text style={[styles.header, { color: theme.faint }]}>{item.header}</Text>
            <Text style={[styles.question, { color: theme.text }]}>{item.question}</Text>
            <View style={styles.options}>
              {item.options.map((option) => {
                const selected = answers[item.id]?.includes(option.label);
                return (
                  <Pressable
                    accessibilityRole={item.multi_select ? "checkbox" : "radio"}
                    accessibilityState={{ checked: selected }}
                    key={option.label}
                    onPress={() => toggle(item.id, option.label, item.multi_select)}
                    style={[styles.option, { borderColor: selected ? theme.accent : theme.line, backgroundColor: selected ? theme.accentSoft : theme.raised }]}
                  >
                    <Text style={[styles.optionLabel, { color: selected ? theme.accent : theme.text }]}>{option.label}</Text>
                    {option.description ? <Text style={{ color: theme.muted, lineHeight: 19 }}>{option.description}</Text> : null}
                  </Pressable>
                );
              })}
            </View>
            {item.allow_free_text ? (
              <TextField
                label="Add a note"
                multiline
                value={notes[item.id] ?? ""}
                onChangeText={(value) => setNotes((current) => ({ ...current, [item.id]: value }))}
                placeholder="Type a custom answer or context"
              />
            ) : null}
          </Card>
        ))}
        <ErrorNotice message={error} />
        <Button label="Send answer" busy={busy} onPress={() => void submit()} />
      </ScrollScreen>
    </View>
  );
}

const styles = StyleSheet.create({
  card: { padding: 16, gap: 12 },
  header: { fontSize: 11, fontWeight: "700", letterSpacing: 0.8, textTransform: "uppercase" },
  question: { fontSize: 17, lineHeight: 24, fontWeight: "600" },
  options: { gap: 8 },
  option: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 11, padding: 12, gap: 4 },
  optionLabel: { fontSize: 15, fontWeight: "700" },
});
