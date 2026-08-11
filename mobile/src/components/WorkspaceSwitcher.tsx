import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import { relayLabel, workspaceInitials, workspaceLabel, type PairedSession } from "@/lib/paired";
import { usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";
import { Icon, Sheet } from "./ui";

/// Four squares of the mark, coloured from the workspace's own identity so two
/// workspaces never look alike in the switcher.
const TILES = ["#2f79f7", "#45d6cc", "#ff8a50", "#b56ce8"];

export function workspaceTint(session: PairedSession) {
  let hash = 0;
  for (const character of session.baseUrl) hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
  return TILES[hash % TILES.length];
}

export function WorkspaceMark({ session, size = 26 }: { session: PairedSession; size?: number }) {
  const tint = workspaceTint(session);
  return (
    <View style={[styles.mark, { width: size, height: size, borderRadius: size * 0.3, backgroundColor: tint }]}>
      <Text style={[styles.markText, { fontSize: size * 0.42 }]}>{workspaceInitials(session)}</Text>
    </View>
  );
}

export function WorkspaceSheet({
  visible,
  onClose,
  workspaces,
  active,
}: {
  visible: boolean;
  onClose: () => void;
  workspaces: PairedSession[];
  active: PairedSession;
}) {
  const theme = useTheme();
  const router = useRouter();
  const { switchTo } = usePairedSession();

  const choose = async (session: PairedSession) => {
    onClose();
    if (session.baseUrl === active.baseUrl) return;
    await switchTo(session.baseUrl);
    router.replace("/inbox");
  };

  return (
    <Sheet visible={visible} title="Workspaces" onClose={onClose}>
      <ScrollView contentContainerStyle={styles.list}>
        {workspaces.map((session) => {
          const current = session.baseUrl === active.baseUrl;
          return (
            <Pressable
              key={session.baseUrl}
              accessibilityRole="button"
              accessibilityState={{ selected: current }}
              onPress={() => void choose(session)}
              style={({ pressed }) => [
                styles.row,
                { borderBottomColor: theme.line },
                current && { backgroundColor: theme.accentSoft },
                pressed && { opacity: 0.6 },
              ]}
            >
              <WorkspaceMark session={session} size={38} />
              <View style={styles.rowMain}>
                <Text numberOfLines={1} style={[styles.rowTitle, { color: theme.text }]}>
                  {workspaceLabel(session)}
                </Text>
                <Text numberOfLines={1} style={[styles.rowDetail, { color: theme.muted }]}>
                  {relayLabel(session)}
                </Text>
              </View>
              {current ? (
                <Icon name={{ ios: "checkmark", android: "check", web: "check" }} color={theme.accent} size={18} />
              ) : null}
            </Pressable>
          );
        })}
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            onClose();
            router.push("/pair");
          }}
          style={({ pressed }) => [styles.row, pressed && { opacity: 0.6 }]}
        >
          <View style={[styles.addMark, { borderColor: theme.line }]}>
            <Icon name={{ ios: "plus", android: "add", web: "add" }} color={theme.accent} size={20} />
          </View>
          <View style={styles.rowMain}>
            <Text style={[styles.rowTitle, { color: theme.accent }]}>Pair another workspace</Text>
            <Text style={[styles.rowDetail, { color: theme.muted }]}>
              Scan a pairing code from that workspace's Desktop
            </Text>
          </View>
        </Pressable>
      </ScrollView>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  mark: { alignItems: "center", justifyContent: "center" },
  markText: { color: "#ffffff", fontWeight: "800" },
  list: { paddingBottom: 24 },
  row: {
    minHeight: 68,
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 18,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  rowMain: { flex: 1, minWidth: 0, gap: 2 },
  rowTitle: { fontSize: 16, fontWeight: "700" },
  rowDetail: { fontSize: 13 },
  addMark: {
    width: 38,
    height: 38,
    borderRadius: 11,
    borderWidth: StyleSheet.hairlineWidth,
    borderStyle: "dashed",
    alignItems: "center",
    justifyContent: "center",
  },
});
