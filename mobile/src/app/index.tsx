// One screen, two states: a phone that has been paired, and one that has not.
//
// There is nothing in between: no token to type, no relay address to guess.
// A paired phone loads the workspace once and again whenever it comes back to
// the foreground, which is all a phone that is not running agents needs.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  AppState,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

import { ApiError } from "@client/api";
import type { Bootstrap, TaskStatus } from "@client/types";
import { apiFor, usePairedSession, type PairedSession } from "@/lib/session";
import { useTheme, type Palette } from "@/lib/theme";

export default function Screen() {
  const { session, signOut } = usePairedSession();
  const theme = useTheme();

  if (session === undefined) {
    return (
      <SafeAreaView style={[styles.fill, styles.centre, { backgroundColor: theme.bg }]}>
        <ActivityIndicator color={theme.accent} />
      </SafeAreaView>
    );
  }

  return session ? (
    <Workspace session={session} onSignOut={signOut} />
  ) : (
    <NotPaired />
  );
}

/// The mark from the desktop icon: four bubbles, one conversation.
function Mark() {
  return (
    <View style={styles.mark} accessible accessibilityLabel="Patchwork">
      {["#2f79f7", "#45d6cc", "#ff8a50", "#b56ce8"].map(
        (colour, index) => (
          <View key={index} style={[styles.markCell, { backgroundColor: colour }]} />
        ),
      )}
    </View>
  );
}

function NotPaired() {
  const theme = useTheme();
  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: theme.bg }]}>
      <View style={[styles.fill, styles.centre, styles.pad]}>
        <Mark />
        <Text
          accessibilityRole="header"
          style={[styles.wordmark, { color: theme.text }]}
        >
          Patchwork
        </Text>
        <Text style={[styles.lede, { color: theme.muted }]}>
          Pair this phone from Desktop.
        </Text>
        <View style={[styles.card, styles.cardTight, { backgroundColor: theme.surface, borderColor: theme.line }]}>
          <Text style={[styles.body, { color: theme.muted }]}>
            Patchwork on a phone is a second window onto a workspace your
            computer already belongs to. The desktop app hands this device its
            own key, and it stays in the keychain: there is nothing to type
            here and nothing to lose in a screenshot.
          </Text>
          <Text style={[styles.body, { color: theme.faint }]}>
            Pairing is not part of this build yet.
          </Text>
        </View>
      </View>
    </SafeAreaView>
  );
}

type Load =
  | { status: "loading" }
  | { status: "ready"; data: Bootstrap }
  | { status: "error"; message: string };

function Workspace({
  session,
  onSignOut,
}: {
  session: PairedSession;
  onSignOut: () => void;
}) {
  const theme = useTheme();
  const [state, setState] = useState<Load>({ status: "loading" });
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      setState({ status: "ready", data: await apiFor(session).bootstrap() });
    } catch (error) {
      const gone =
        error instanceof ApiError && (error.status === 401 || error.status === 403);
      setState({
        status: "error",
        message: gone
          ? "This phone is no longer paired with that workspace."
          : error instanceof Error
            ? error.message
            : String(error),
      });
    }
  }, [session]);

  // Foreground only. Nothing listens while the app is away, so coming back is
  // the moment to catch up, and the only one.
  const appState = useRef(AppState.currentState);
  useEffect(() => {
    void load();
    const subscription = AppState.addEventListener("change", (next) => {
      const returning =
        /inactive|background/.test(appState.current) && next === "active";
      appState.current = next;
      if (returning) void load();
    });
    return () => subscription.remove();
  }, [load]);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  }, [load]);

  const data = state.status === "ready" ? state.data : undefined;

  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: theme.bg }]}>
      <View style={[styles.header, { borderBottomColor: theme.line }]}>
        <View style={styles.fill}>
          <Text style={[styles.eyebrow, { color: theme.faint }]}>Patchwork</Text>
          <Text
            accessibilityRole="header"
            numberOfLines={1}
            style={[styles.title, { color: theme.text }]}
          >
            {data ? data.workspace.name : "\u2026"}
          </Text>
        </View>
        <Pressable
          onPress={onSignOut}
          accessibilityRole="button"
          accessibilityLabel="Sign out of this workspace"
          hitSlop={8}
          style={({ pressed }) => [styles.quiet, pressed && styles.pressed]}
        >
          <Text style={[styles.quietText, { color: theme.muted }]}>Sign out</Text>
        </Pressable>
      </View>

      {state.status === "loading" ? (
        <View style={[styles.fill, styles.centre]}>
          <ActivityIndicator color={theme.accent} />
        </View>
      ) : state.status === "error" ? (
        <View style={[styles.fill, styles.centre, styles.pad]}>
          <Text style={[styles.body, styles.middle, { color: theme.danger }]}>
            {state.message}
          </Text>
          <Pressable
            onPress={() => {
              setState({ status: "loading" });
              void load();
            }}
            accessibilityRole="button"
            accessibilityLabel="Try loading the workspace again"
            style={({ pressed }) => [
              styles.button,
              { backgroundColor: theme.accentSoft },
              pressed && styles.pressed,
            ]}
          >
            <Text style={[styles.buttonText, { color: theme.accent }]}>Retry</Text>
          </Pressable>
        </View>
      ) : (
        <Ready data={state.data} theme={theme} refreshing={refreshing} onRefresh={refresh} />
      )}
    </SafeAreaView>
  );
}

function Ready({
  data,
  theme,
  refreshing,
  onRefresh,
}: {
  data: Bootstrap;
  theme: Palette;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const unread = data.inbox.filter((item) => !item.read_at).length;
  const questions = data.open_questions;
  const open = data.tasks.filter((task) => task.status !== "done");
  const name = (id?: string) =>
    data.members.find((member) => member.id === id)?.display_name;

  return (
    <ScrollView
      contentContainerStyle={styles.scroll}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={onRefresh}
          tintColor={theme.muted}
          colors={[theme.accent]}
        />
      }
    >
      <View style={styles.stats}>
        <Stat label="Unread" value={unread} theme={theme} tint={unread ? theme.accent : undefined} />
        <Stat label="Questions" value={questions.length} theme={theme} tint={questions.length ? theme.caution : undefined} />
        <Stat label="Open tasks" value={open.length} theme={theme} />
      </View>

      <Section title="Waiting on you" theme={theme}>
        {questions.length === 0 ? (
          <Empty theme={theme}>No agent is blocked on a decision.</Empty>
        ) : (
          questions.map((question) => (
            <Row
              key={question.id}
              theme={theme}
              title={question.headline}
              detail={name(question.agent_id) ?? "An agent"}
              tag="asks"
              tagColour={theme.caution}
            />
          ))
        )}
      </Section>

      <Section title="Tasks" theme={theme}>
        {open.length === 0 ? (
          <Empty theme={theme}>Nothing open.</Empty>
        ) : (
          open.map((task) => (
            <Row
              key={task.id}
              theme={theme}
              title={task.title}
              detail={[task.key, name(task.owner_id)].filter(Boolean).join(" \u00b7 ")}
              tag={task.status}
              tagColour={statusColour(task.status, theme)}
            />
          ))
        )}
      </Section>

      <Text style={[styles.footer, { color: theme.faint }]}>
        Signed in as {data.me.display_name}
      </Text>
    </ScrollView>
  );
}

function statusColour(status: TaskStatus, theme: Palette) {
  if (status === "blocked") return theme.danger;
  if (status === "review") return theme.caution;
  if (status === "running") return theme.accent;
  return theme.faint;
}

function Stat({
  label,
  value,
  theme,
  tint,
}: {
  label: string;
  value: number;
  theme: Palette;
  tint?: string;
}) {
  return (
    <View
      accessible
      accessibilityLabel={`${label}: ${value}`}
      style={[styles.stat, { backgroundColor: theme.surface, borderColor: theme.line }]}
    >
      <Text style={[styles.statValue, { color: tint ?? theme.text }]}>{value}</Text>
      <Text style={[styles.statLabel, { color: theme.muted }]}>{label}</Text>
    </View>
  );
}

function Section({
  title,
  theme,
  children,
}: {
  title: string;
  theme: Palette;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.section}>
      <Text accessibilityRole="header" style={[styles.sectionTitle, { color: theme.faint }]}>
        {title}
      </Text>
      <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }]}>
        {children}
      </View>
    </View>
  );
}

function Row({
  theme,
  title,
  detail,
  tag,
  tagColour,
}: {
  theme: Palette;
  title: string;
  detail: string;
  tag: string;
  tagColour: string;
}) {
  return (
    <View accessible accessibilityLabel={`${title}. ${detail}. ${tag}`} style={styles.row}>
      <View style={styles.fill}>
        <Text numberOfLines={2} style={[styles.rowTitle, { color: theme.text }]}>
          {title}
        </Text>
        {detail ? (
          <Text style={[styles.rowDetail, { color: theme.muted }]}>{detail}</Text>
        ) : null}
      </View>
      <Text style={[styles.tag, { color: tagColour }]}>{tag}</Text>
    </View>
  );
}

function Empty({ theme, children }: { theme: Palette; children: React.ReactNode }) {
  return <Text style={[styles.empty, { color: theme.faint }]}>{children}</Text>;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  centre: { alignItems: "center", justifyContent: "center" },
  pad: { paddingHorizontal: 24, gap: 12 },
  middle: { textAlign: "center" },

  mark: {
    width: 76,
    height: 76,
    flexDirection: "row",
    flexWrap: "wrap",
    gap: 6,
    marginBottom: 20,
  },
  markCell: { width: 35, height: 35, borderRadius: 11 },
  wordmark: { fontSize: 30, fontWeight: "700", letterSpacing: -0.5 },
  lede: { fontSize: 16, textAlign: "center" },

  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 20,
    paddingBottom: 12,
    paddingTop: 4,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  eyebrow: { fontSize: 11, fontWeight: "600", letterSpacing: 0.8, textTransform: "uppercase" },
  title: { fontSize: 22, fontWeight: "700", letterSpacing: -0.3 },
  quiet: { paddingVertical: 6, paddingHorizontal: 4 },
  quietText: { fontSize: 15 },
  pressed: { opacity: 0.55 },

  scroll: { padding: 20, gap: 24 },
  stats: { flexDirection: "row", gap: 10 },
  stat: {
    flex: 1,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 12,
    paddingVertical: 14,
    paddingHorizontal: 12,
    gap: 2,
  },
  statValue: { fontSize: 26, fontWeight: "700" },
  statLabel: { fontSize: 12 },

  section: { gap: 8 },
  sectionTitle: { fontSize: 11, fontWeight: "600", letterSpacing: 0.8, textTransform: "uppercase" },
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 12, overflow: "hidden" },
  cardTight: { padding: 16, gap: 12 },

  row: {
    flexDirection: "row",
    alignItems: "flex-start",
    gap: 12,
    paddingVertical: 12,
    paddingHorizontal: 14,
  },
  rowTitle: { fontSize: 15, fontWeight: "600" },
  rowDetail: { fontSize: 13, marginTop: 2 },
  tag: { fontSize: 12, fontWeight: "600" },

  empty: { fontSize: 14, paddingVertical: 14, paddingHorizontal: 14 },
  body: { fontSize: 15, lineHeight: 22 },
  footer: { fontSize: 12, textAlign: "center" },

  button: {
    minHeight: 44,
    justifyContent: "center",
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 20,
  },
  buttonText: { fontSize: 15, fontWeight: "600" },
});
