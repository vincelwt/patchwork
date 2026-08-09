import { useEffect, useState } from "react";
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";

import type { RunEvent } from "@client/types";
import { PendingImages, useImageAttachments } from "@/components/Attachment";
import { Markdown } from "@/components/Markdown";
import { Avatar, Badge, Button, Card, Empty, ErrorNotice, PageHeader } from "@/components/ui";
import { useDictation } from "@/lib/dictation";
import { duration, relative, runStatusLabel } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { useBottomAnchoredList } from "@/lib/scroll";

export default function RunScreen() {
  const { runId } = useLocalSearchParams<{ runId: string }>();
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const detail = workspace.runDetails[runId];
  const run = detail?.run ?? workspace.bootstrap?.active_runs.find((item) => item.id === runId);
  const agent = workspace.bootstrap?.members.find((member) => member.id === run?.agent_id);
  const host = workspace.bootstrap?.hosts.find((item) => item.id === run?.host_id);
  const question = detail?.questions.find((item) => item.status === "open")
    ?? workspace.bootstrap?.open_questions.find((item) => item.run_id === runId);
  const events = detail?.events ?? [];
  const anchor = useBottomAnchoredList<RunEvent>(
    runId,
    run ? events.length + 1 : 0,
  );

  useEffect(() => {
    void store.loadRun(runId);
  }, [runId, store]);

  if (!run) return <View style={styles.fill}><PageHeader title="Run" back /><Empty title="Loading run" /></View>;
  const active = !["succeeded", "failed", "cancelled"].includes(run.status);
  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader
        title={agent?.display_name || "Agent run"}
        subtitle={run.headline || runStatusLabel(run.status)}
        back
        action={active ? <Button label="Stop" compact tone="danger" onPress={() => void store.mutate((api) => api.cancelRun(run.id))} /> : undefined}
      />
      <FlatList
        ref={anchor.listRef}
        data={events}
        keyExtractor={(event) => event.id}
        contentContainerStyle={styles.list}
        onContentSizeChange={anchor.onContentSizeChange}
        onScroll={anchor.onScroll}
        onScrollBeginDrag={anchor.onScrollBeginDrag}
        onScrollEndDrag={anchor.onScrollEndDrag}
        onMomentumScrollBegin={anchor.onMomentumScrollBegin}
        onMomentumScrollEnd={anchor.onMomentumScrollEnd}
        scrollEventThrottle={16}
        ListHeaderComponent={
          <View style={styles.headerContent}>
            <Card style={styles.summary}>
              <View style={styles.summaryHead}>
                <Avatar member={agent} />
                <View style={styles.grow}>
                  <Text style={[styles.headline, { color: theme.text }]}>{run.headline || run.prompt}</Text>
                  <Text style={{ color: theme.muted }}>{relative(run.created_at)}</Text>
                </View>
                <Badge tone={run.status === "failed" ? "danger" : run.status === "waiting" ? "caution" : run.status === "succeeded" ? "positive" : "accent"}>{runStatusLabel(run.status)}</Badge>
              </View>
              <View style={styles.meta}>
                <Badge>{run.runtime}</Badge>
                {host ? <Badge tone={host.online ? "positive" : "neutral"}>{host.name}</Badge> : null}
                <Badge>{duration(run.started_at, run.ended_at)}</Badge>
              </View>
              {run.cwd ? <Text selectable style={[styles.cwd, { color: theme.faint }]}>{run.cwd}</Text> : null}
              {run.error ? <Text selectable style={[styles.runError, { color: theme.danger }]}>{run.error}</Text> : null}
            </Card>
            {question ? (
              <Pressable
                onPress={() => router.push({ pathname: "/(app)/questions/[questionId]", params: { questionId: question.id } })}
                style={[styles.question, { backgroundColor: theme.cautionSoft }]}
              >
                <Text style={{ color: theme.caution, fontWeight: "700" }}>Waiting for your answer</Text>
                <Text style={{ color: theme.text }}>{question.headline}</Text>
              </Pressable>
            ) : null}
            <Text style={[styles.section, { color: theme.faint }]}>ACTIVITY</Text>
            {!events.length ? <Empty title={active ? "Waiting for activity" : "Nothing was recorded"} /> : null}
          </View>
        }
        renderItem={({ item }) => <RunEventRow event={item} />}
        initialNumToRender={30}
        windowSize={10}
      />
      {active ? <RunSteer runId={run.id} taskId={run.task_id} agentName={agent?.display_name || "agent"} /> : null}
    </View>
  );
}

function RunEventRow({ event }: { event: RunEvent }) {
  const theme = useTheme();
  const prose = ["message", "plan", "thought", "lifecycle"].includes(event.kind);
  return (
    <View style={[styles.event, event.kind === "error" && { backgroundColor: theme.dangerSoft }]}>
      <Text style={[styles.eventKind, { color: event.kind === "error" ? theme.danger : theme.faint }]}>{event.kind.replace("_", " ")}</Text>
      <View style={styles.grow}>{prose ? <Markdown body={event.text} compact /> : <Text selectable style={[styles.eventText, { color: theme.text }]}>{event.text}</Text>}</View>
    </View>
  );
}

function RunSteer({ runId, taskId, agentName }: { runId: string; taskId?: string; agentName: string }) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const images = useImageAttachments(taskId);
  const dictation = useDictation(setText);
  const send = async (mode: "queue" | "interrupt") => {
    if ((!text.trim() && !images.pending.length) || busy) return;
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) => api.steerRun(runId, { prompt: text.trim(), mode, attachment_ids: images.pending.map((item) => item.attachment.id) }),
        false,
      );
      setText("");
      images.clear();
      await store.loadRun(runId);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };
  return (
    <View style={[styles.steer, { borderTopColor: theme.line, backgroundColor: theme.bg }]}>
      <Text style={[styles.steerTarget, { color: theme.muted }]}>Straight to {agentName} in this run</Text>
      <PendingImages images={images.pending} onRemove={images.remove} />
      <View style={[styles.steerBox, { backgroundColor: theme.input, borderColor: theme.line }]}>
        <TextInput
          multiline
          value={text}
          onChangeText={setText}
          placeholder={workspace.connection === "live" ? `Tell ${agentName} something` : "Reconnect to steer this run"}
          placeholderTextColor={theme.faint}
          style={[styles.steerInput, { color: theme.text }]}
        />
        <View style={styles.steerActions}>
          <Button label="Image" compact tone="quiet" onPress={() => void images.pick()} />
          {dictation.supported ? <Button label={dictation.recording ? "Stop mic" : "Dictate"} compact tone="quiet" onPress={() => (dictation.recording ? dictation.stop() : void dictation.start(text))} /> : null}
          <View style={styles.grow} />
          <Button label="Interrupt" compact tone="secondary" disabled={workspace.connection !== "live"} onPress={() => void send("interrupt")} />
          <Button label="Queue" compact busy={busy} disabled={workspace.connection !== "live"} onPress={() => void send("queue")} />
        </View>
      </View>
      <ErrorNotice message={error || images.error || dictation.error} />
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  grow: { flex: 1 },
  list: { paddingBottom: 16 },
  headerContent: { padding: 12, gap: 12 },
  summary: { padding: 13, gap: 10 },
  summaryHead: { flexDirection: "row", alignItems: "center", gap: 10 },
  headline: { fontSize: 16, fontWeight: "700" },
  meta: { flexDirection: "row", flexWrap: "wrap", gap: 6 },
  cwd: { fontSize: 11 },
  runError: { fontSize: 14, lineHeight: 20 },
  question: { borderRadius: 11, padding: 13, gap: 4 },
  section: { fontSize: 11, fontWeight: "700", letterSpacing: 0.8 },
  event: { flexDirection: "row", gap: 10, paddingHorizontal: 14, paddingVertical: 8 },
  eventKind: { width: 72, fontSize: 10, fontWeight: "700", textTransform: "uppercase" },
  eventText: { fontSize: 13, lineHeight: 19, fontFamily: "monospace" },
  steer: { borderTopWidth: StyleSheet.hairlineWidth, padding: 10, gap: 5 },
  steerTarget: { fontSize: 11, fontWeight: "600" },
  steerBox: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 12, padding: 8 },
  steerInput: { minHeight: 38, maxHeight: 120, fontSize: 15, textAlignVertical: "top" },
  steerActions: { flexDirection: "row", alignItems: "center", gap: 5, marginTop: 5 },
});
