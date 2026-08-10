import { useState } from "react";
import { Platform, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import DateTimePicker from "@react-native-community/datetimepicker";

import type { Task, TaskStatus } from "@client/types";
import { TASK_STATUSES } from "@client/types";
import { useDictation } from "@/lib/dictation";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { PendingImages, useImageAttachments } from "./Attachment";
import { Button, ChoiceField, ErrorNotice, TextField, ToggleRow } from "./ui";

export function TaskEditor({ task, onSaved }: { task?: Task; onSaved: (task: Task) => void }) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const [title, setTitle] = useState(task?.title ?? "");
  const [outcome, setOutcome] = useState(task?.outcome ?? "");
  const [owner, setOwner] = useState(task?.owner_id ?? data?.me.id ?? "");
  const [project, setProject] = useState(task?.project_id ?? "");
  const [status, setStatus] = useState<TaskStatus>(task?.status ?? "planned");
  const [due, setDue] = useState<Date | null>(task?.due_at ? new Date(task.due_at) : null);
  const [showDate, setShowDate] = useState(false);
  const [start, setStart] = useState(!task);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const images = useImageAttachments(task?.id);
  const dictation = useDictation(setOutcome);
  if (!data) return null;

  const ownerMember = data.members.find((member) => member.id === owner);
  const save = async () => {
    if (!outcome.trim() && !title.trim()) return;
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) => task
          ? api.updateTask(task.id, {
              title: title.trim(),
              outcome: outcome.trim(),
              owner_id: owner || undefined,
              project_id: project || undefined,
              status,
              due_at: due?.getTime() ?? 0,
            })
          : api.createTask({
              title: title.trim(),
              outcome: outcome.trim(),
              owner_id: owner || undefined,
              project_id: project || undefined,
              due_at: due?.getTime() || undefined,
              attachment_ids: images.pending.map((item) => item.attachment.id),
              start: start && ownerMember?.kind === "agent",
            }),
        true,
        onSaved,
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.form} keyboardShouldPersistTaps="handled">
      {task ? <TextField label="Title" value={title} onChangeText={setTitle} /> : null}
      <View>
        <TextField
          label={task ? "Outcome" : "What needs to happen?"}
          multiline
          value={outcome}
          onChangeText={setOutcome}
          placeholder="Describe the expected result"
        />
        {dictation.supported ? (
          <Pressable
            onPress={() => (dictation.recording ? dictation.stop() : void dictation.start(outcome))}
            style={[styles.dictate, { backgroundColor: dictation.recording ? theme.dangerSoft : theme.accentSoft }]}
          >
            <Text style={{ color: dictation.recording ? theme.danger : theme.accent, fontWeight: "700" }}>
              {dictation.recording ? "Stop dictation" : "Dictate"}
            </Text>
          </Pressable>
        ) : null}
      </View>
      <ChoiceField
        label="Owner"
        value={owner}
        options={[{ value: "", label: "Unassigned" }, ...data.members.map((member) => ({ value: member.id, label: member.display_name, description: member.kind === "agent" ? `Agent · ${member.agent?.runtime}` : "Person" }))]}
        onChange={setOwner}
      />
      <ChoiceField
        label="Project"
        value={project}
        options={[{ value: "", label: "No project" }, ...data.projects.map((item) => ({ value: item.id, label: item.name, description: item.description }))]}
        onChange={setProject}
      />
      {task ? (
        <ChoiceField
          label="Status"
          value={status}
          options={TASK_STATUSES.map((item) => ({ value: item, label: item[0].toUpperCase() + item.slice(1) }))}
          onChange={(value) => setStatus(value as TaskStatus)}
        />
      ) : null}
      <View style={styles.dateRow}>
        <View style={styles.dateText}>
          <Text style={{ color: theme.text, fontWeight: "600" }}>Due date</Text>
          <Text style={{ color: theme.muted }}>{due ? due.toLocaleDateString() : "No date"}</Text>
        </View>
        <Button label={due ? "Change" : "Add"} compact tone="secondary" onPress={() => setShowDate(true)} />
        {due ? <Button label="Clear" compact tone="quiet" onPress={() => setDue(null)} /> : null}
      </View>
      {showDate ? (
        <DateTimePicker
          value={due ?? new Date()}
          mode="date"
          display={Platform.OS === "ios" ? "inline" : "default"}
          onChange={(_, value) => {
            if (Platform.OS !== "ios") setShowDate(false);
            if (value) setDue(value);
          }}
        />
      ) : null}
      {!task ? (
        <>
          <Button label={images.uploading ? "Uploading…" : "Attach images"} tone="secondary" disabled={images.uploading} onPress={() => void images.pick()} />
          <PendingImages images={images.pending} onRemove={images.remove} />
          <ToggleRow label="Start immediately" detail="Starts only when the owner is an agent." value={start} onChange={setStart} />
        </>
      ) : null}
      <ErrorNotice message={error || images.error || dictation.error} />
      <Button
        label={task ? "Save task" : "Create task"}
        busy={busy}
        disabled={(!outcome.trim() && !title.trim()) || images.uploading}
        onPress={() => void save()}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  form: { padding: 16, gap: 15, paddingBottom: 36 },
  dictate: { alignSelf: "flex-start", minHeight: 38, borderRadius: 10, paddingHorizontal: 12, alignItems: "center", justifyContent: "center", marginTop: 6 },
  dateRow: { flexDirection: "row", alignItems: "center", gap: 8 },
  dateText: { flex: 1, gap: 2 },
});
