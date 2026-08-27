// Evidence read on the phone: a screenshot, a report, a table or a log, opened
// where it was posted. Anything a phone has a better viewer for is handed to
// that viewer through a granted URL.

import { useCallback, useEffect, useState } from "react";
import { Linking, ScrollView, StyleSheet, Text, View } from "react-native";
import { Image } from "expo-image";

import type { Api } from "@client/api";
import { evidenceKind, parseTable, separatorFor, type EvidenceKind } from "@client/evidence";
import type { Attachment } from "@client/types";
import { apiFor, usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";
import { Markdown } from "./Markdown";
import { ErrorNotice, Loading } from "./ui";

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

/// The attachment itself, sized to sit inside a transcript rather than to own a
/// screen. What opens elsewhere never reaches here.
export function EvidenceBody({ attachment }: { attachment: Attachment }) {
  const kind = evidenceKind(attachment.mime, attachment.file_name);
  return kind === "image" ? <EvidenceImage attachment={attachment} /> : <TextEvidence attachment={attachment} />;
}

/// The relay wants a bearer token that an image URL cannot carry on its own.
function EvidenceImage({ attachment }: { attachment: Attachment }) {
  const { session } = usePairedSession();
  const theme = useTheme();
  if (!session) return null;
  return (
    <Image
      source={{
        uri: `${session.baseUrl.replace(/\/$/, "")}${attachment.url}`,
        headers: { Authorization: `Bearer ${session.token}` },
      }}
      style={[styles.image, { backgroundColor: theme.surface }]}
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
    <ScrollView style={styles.reader} contentContainerStyle={styles.text} nestedScrollEnabled>
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

const styles = StyleSheet.create({
  image: { width: "100%", maxWidth: 460, aspectRatio: 4 / 3, borderRadius: 10 },
  reader: { maxHeight: 420 },
  text: { paddingVertical: 8 },
  note: { fontSize: 13, marginTop: 10 },
  row: { flexDirection: "row", borderBottomWidth: StyleSheet.hairlineWidth },
  cell: { width: 130, paddingVertical: 7, paddingRight: 10, fontSize: 13 },
  headerCell: { fontWeight: "700" },
});
