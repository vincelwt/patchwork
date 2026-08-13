// Evidence read on the phone: a screenshot opens big, a report, a table or a
// log is read in place, and anything a phone has a better viewer for is handed
// to that viewer through a granted URL.

import { useCallback, useEffect, useState } from "react";
import { Linking, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Image } from "expo-image";

import type { Api } from "@client/api";
import { evidenceKind, parseTable, separatorFor, type EvidenceKind } from "@client/evidence";
import type { Attachment, Preview, Task, TaskDetail } from "@client/types";
import { bytes } from "@/lib/format";
import { apiFor, usePairedSession } from "@/lib/session";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";
import { Markdown } from "./Markdown";
import { Button, Empty, ErrorNotice, Loading, Sheet } from "./ui";

/// A phone lays out text a good deal slower than a browser does, so it stops
/// well before Desktop's 400,000 characters. The file itself is one tap away.
const MAX_CHARS = 100_000;
const MAX_TEXT_BYTES = MAX_CHARS * 4;
const MAX_ROWS = 500;

/// What the phone has a better viewer for than Patchwork does, plus HTML, which
/// is somebody else's page and is not worth running inside the app it is
/// evidence for.
export function opensExternally(kind: EvidenceKind) {
  return kind === "video" || kind === "html" || kind === "file";
}

/// Everything that opens somewhere else: a granted URL is absolute and carries
/// its own credential, so the browser, the player or the previewer can take it.
export function useGrantedOpen() {
  const { session } = usePairedSession();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const open = useCallback(
    async (grant: (api: Api) => Promise<{ url: string }>) => {
      if (!session) return;
      setBusy(true);
      setError("");
      try {
        const granted = new URL((await grant(apiFor(session))).url);
        if (granted.protocol !== "https:" && !(__DEV__ && granted.protocol === "http:")) {
          throw new Error("The relay returned an unsafe URL.");
        }
        await Linking.openURL(granted.toString());
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : String(caught));
      } finally {
        setBusy(false);
      }
    },
    [session],
  );

  return { open, busy, error };
}

export function EvidenceView({ attachment }: { attachment: Attachment }) {
  const theme = useTheme();
  const { open, busy, error } = useGrantedOpen();
  const kind = evidenceKind(attachment.mime, attachment.file_name);

  return (
    <View style={styles.fill}>
      <View style={[styles.bar, { borderBottomColor: theme.line }]}>
        <View style={styles.fill}>
          <Text numberOfLines={2} style={[styles.name, { color: theme.text }]}>
            {attachment.caption || attachment.file_name}
          </Text>
          <Text numberOfLines={1} style={{ color: theme.muted }}>
            {attachment.caption ? `${attachment.file_name} · ` : ""}{bytes(attachment.size)}
          </Text>
        </View>
        {/* Also how a phone downloads it, or hands it to a better viewer. */}
        <Button label="Open" compact tone="secondary" busy={busy} onPress={() => void open((api) => api.grantFile(attachment.id))} />
      </View>
      <ErrorNotice message={error} />
      {kind === "image" ? (
        <AuthenticatedImage attachment={attachment} />
      ) : opensExternally(kind) ? (
        // A video, somebody else's page, a PDF: worth showing, not worth
        // rendering inside the app that the evidence is about.
        <Empty
          title="Opens outside Patchwork"
          detail={`This ${kind === "video" ? "video" : kind === "html" ? "page" : "file"} opens in the viewer your phone uses for it.`}
        />
      ) : (
        <TextEvidence attachment={attachment} />
      )}
    </View>
  );
}

/// The relay wants a bearer token that an image URL cannot carry on its own.
function AuthenticatedImage({ attachment }: { attachment: Attachment }) {
  const { session } = usePairedSession();
  const theme = useTheme();
  if (!session) return null;
  return (
    <Image
      source={{
        uri: `${session.baseUrl.replace(/\/$/, "")}${attachment.url}`,
        headers: { Authorization: `Bearer ${session.token}` },
      }}
      style={[styles.fill, { backgroundColor: theme.surface }]}
      contentFit="contain"
      transition={120}
      cachePolicy="none"
      accessibilityLabel={attachment.caption || attachment.file_name}
    />
  );
}

function TextEvidence({ attachment }: { attachment: Attachment }) {
  const theme = useTheme();
  const { session } = usePairedSession();
  const [text, setText] = useState<string>();
  const [failed, setFailed] = useState("");

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    setText(undefined);
    setFailed("");
    void fetch(`${session.baseUrl.replace(/\/$/, "")}${attachment.url}`, {
      headers: {
        Authorization: `Bearer ${session.token}`,
        ...(attachment.size > MAX_TEXT_BYTES
          ? { Range: `bytes=0-${MAX_TEXT_BYTES - 1}` }
          : {}),
      },
    })
      .then(async (response) => {
        if (!response.ok) throw new Error(await response.text());
        return response.text();
      })
      .then((body) => {
        if (!cancelled) setText(body);
      })
      .catch((caught) => {
        if (!cancelled) setFailed(caught instanceof Error ? caught.message : String(caught));
      });
    return () => {
      cancelled = true;
    };
  }, [attachment.size, attachment.url, session]);

  if (failed) return <ErrorNotice message={`That file could not be read. ${failed}`} />;
  if (text === undefined) return <Loading label="Reading" />;

  const clipped = attachment.size > MAX_TEXT_BYTES || text.length > MAX_CHARS;
  const body = clipped ? text.slice(0, MAX_CHARS) : text;
  const kind = evidenceKind(attachment.mime, attachment.file_name);

  return (
    <ScrollView contentContainerStyle={styles.text}>
      {kind === "markdown" ? (
        <Markdown body={body} />
      ) : kind === "csv" ? (
        <Table rows={parseTable(body, separatorFor(attachment.file_name))} />
      ) : (
        <ScrollView horizontal>
          <Text selectable style={{ color: theme.text, fontFamily: "monospace" }}>{body}</Text>
        </ScrollView>
      )}
      {clipped ? (
        <Text style={[styles.note, { color: theme.muted }]}>
          Showing the first {MAX_CHARS.toLocaleString()} characters. Open the file for the rest.
        </Text>
      ) : null}
    </ScrollView>
  );
}

function Table({ rows }: { rows: string[][] }) {
  const theme = useTheme();
  const [header, ...body] = rows;
  if (!header) return <Text style={{ color: theme.muted }}>That file is empty.</Text>;
  const shown = body.slice(0, MAX_ROWS);
  return (
    <ScrollView horizontal>
      <View>
        {[header, ...shown].map((row, index) => (
          <View key={index} style={[styles.row, { borderBottomColor: theme.line }]}>
            {row.map((cell, at) => (
              <Text
                key={at}
                selectable
                style={[styles.cell, { color: index ? theme.text : theme.muted }, !index && styles.headerCell]}
              >
                {cell}
              </Text>
            ))}
          </View>
        ))}
        {body.length > shown.length ? (
          <Text style={[styles.note, { color: theme.muted }]}>Showing {shown.length} of {body.length} rows.</Text>
        ) : null}
      </View>
    </ScrollView>
  );
}

/// Everything a run left behind for this task, in one sheet: the attachments it
/// posted and whatever it has running. Loaded while the sheet is open, because
/// the discussion is what the screen is for.
export function TaskEvidence({
  task,
  visible,
  onClose,
}: {
  task: Task;
  visible: boolean;
  onClose: () => void;
}) {
  const theme = useTheme();
  const workspace = useWorkspace();
  const { session } = usePairedSession();
  const [detail, setDetail] = useState<TaskDetail>();
  const [error, setError] = useState("");
  const [selected, setSelected] = useState("");
  // What actually makes this stale: the run posting something, or a preview
  // starting, stopping or failing.
  const messages = workspace.messages[task.discussion_channel_id]?.length ?? 0;
  const previews = (workspace.bootstrap?.previews ?? [])
    .filter((preview) => preview.task_id === task.id)
    .map((preview) => `${preview.id}:${preview.status}`)
    .join(",");

  useEffect(() => {
    if (!visible || !session) return;
    let cancelled = false;
    setError("");
    void apiFor(session)
      .task(task.id)
      .then((next) => {
        if (!cancelled) setDetail(next);
      })
      .catch((caught) => {
        if (!cancelled) setError(caught instanceof Error ? caught.message : String(caught));
      });
    return () => {
      cancelled = true;
    };
  }, [visible, session, task.id, messages, previews]);

  useEffect(() => setSelected(""), [task.id]);

  const currentDetail = detail?.task.id === task.id ? detail : undefined;
  const items = visible ? [
    ...(currentDetail?.attachments ?? []).map((attachment) => ({ id: attachment.id, attachment, preview: undefined })),
    ...(currentDetail?.previews ?? [])
      .filter((preview) => preview.status === "live")
      .map((preview) => ({ id: preview.id, attachment: undefined, preview })),
  ] : [];
  const chosen = items.find((item) => item.id === selected) ?? items[0];

  return (
    <Sheet visible={visible} title={`${task.key} evidence`} onClose={onClose}>
      {items.length > 1 ? (
        <ScrollView horizontal style={styles.pickerScroll} contentContainerStyle={styles.picker} showsHorizontalScrollIndicator={false}>
          {items.map((item) => {
            const label = item.preview
              ? item.preview.label
              : item.attachment!.caption || item.attachment!.file_name;
            const active = item.id === chosen?.id;
            return (
              <Pressable
                key={item.id}
                accessibilityRole="button"
                accessibilityState={{ selected: active }}
                accessibilityLabel={label}
                onPress={() => setSelected(item.id)}
                style={[styles.pick, { backgroundColor: active ? theme.accentSoft : theme.surface, borderColor: theme.line }]}
              >
                <Text numberOfLines={1} style={{ color: active ? theme.accent : theme.text, fontWeight: "600" }}>{label}</Text>
              </Pressable>
            );
          })}
        </ScrollView>
      ) : null}
      {chosen?.attachment ? (
        <EvidenceView attachment={chosen.attachment} />
      ) : chosen?.preview ? (
        <PreviewView preview={chosen.preview} />
      ) : !currentDetail ? (
        error || workspace.connection === "offline" ? (
          <Empty
            title={workspace.connection === "offline" ? "Offline" : "Could not load the evidence"}
            detail={workspace.connection === "offline" ? "Reconnect to see what this task has attached." : error}
          />
        ) : (
          <Loading />
        )
      ) : (
        <Empty title="No evidence yet" detail="Screenshots, reports, and live previews posted by a run appear here." />
      )}
      {currentDetail ? <ErrorNotice message={error} /> : null}
    </Sheet>
  );
}

function PreviewView({ preview }: { preview: Preview }) {
  const theme = useTheme();
  const { open, busy, error } = useGrantedOpen();
  return (
    <View style={styles.fill}>
      <View style={[styles.bar, { borderBottomColor: theme.line }]}>
        <View style={styles.fill}>
          <Text numberOfLines={2} style={[styles.name, { color: theme.text }]}>{preview.label}</Text>
          <Text numberOfLines={1} style={{ color: theme.muted }}>
            port {preview.port} · {preview.status}
          </Text>
        </View>
        <Button label="Open" compact tone="secondary" busy={busy} onPress={() => void open((api) => api.grantPreview(preview.id))} />
      </View>
      <ErrorNotice message={error} />
      <Empty title="A running site" detail="Previews open in your browser, where they can be used properly." />
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  bar: { flexDirection: "row", alignItems: "center", gap: 10, padding: 14, borderBottomWidth: StyleSheet.hairlineWidth },
  name: { fontSize: 15, fontWeight: "700" },
  text: { padding: 14, paddingBottom: 34 },
  note: { fontSize: 13, marginTop: 10 },
  row: { flexDirection: "row", borderBottomWidth: StyleSheet.hairlineWidth },
  cell: { width: 130, paddingVertical: 7, paddingRight: 10, fontSize: 13 },
  headerCell: { fontWeight: "700" },
  pickerScroll: { flexGrow: 0, maxHeight: 60 },
  picker: { gap: 8, padding: 12 },
  pick: { maxWidth: 220, height: 36, justifyContent: "center", borderRadius: 999, borderWidth: StyleSheet.hairlineWidth, paddingHorizontal: 14 },
});
