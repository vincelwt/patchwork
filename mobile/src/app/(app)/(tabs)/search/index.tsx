import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router, Stack, useFocusEffect } from "expo-router";
import type { SearchBarCommands } from "react-native-screens";

import type { SearchResults } from "@client/types";
import { ErrorNotice, Glass, Icon, Measured, Screen } from "@/components/ui";
import { relative } from "@/lib/format";
import { useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function SearchScreen() {
  const theme = useTheme();
  const store = useWorkspaceStore();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const request = useRef(0);
  const nativeSearch = process.env.EXPO_OS === "ios";
  const searchBar = useRef<SearchBarCommands>(null);
  const input = useRef<TextInput>(null);
  // Read on focus rather than closed over, so returning to a search that still
  // has its query sees the current one.
  const typed = useRef("");
  typed.current = query;

  // Reaching this tab is the whole intent, so the caret is already waiting.
  // A search that still has its query keeps its results readable instead.
  useFocusEffect(
    useCallback(() => {
      if (typed.current) return;
      const frame = requestAnimationFrame(() => (nativeSearch ? searchBar : input).current?.focus());
      return () => cancelAnimationFrame(frame);
    }, [nativeSearch]),
  );

  useEffect(() => {
    const value = query.trim();
    const current = ++request.current;
    setError("");
    if (!value) {
      setResults(undefined);
      setLoading(false);
      return;
    }

    setLoading(true);
    const timer = setTimeout(() => {
      void store.mutate(
        (api) => api.search(value),
        false,
        (next) => {
          if (request.current !== current) return;
          setResults(next);
          setLoading(false);
        },
      ).catch(
        (caught) => {
          if (request.current !== current) return;
          setError(caught instanceof Error ? caught.message : String(caught));
          setLoading(false);
        },
      );
    }, 250);
    return () => clearTimeout(timer);
  }, [query, store]);

  const total = (results?.messages.length ?? 0) + (results?.tasks.length ?? 0);

  return (
    <Screen style={{ backgroundColor: theme.surface }}>
      <Stack.Screen
        options={{
          headerSearchBarOptions: nativeSearch
            ? {
                ref: searchBar,
                autoCapitalize: "none",
                autoFocus: true,
                hideNavigationBar: false,
                hideWhenScrolling: false,
                onCancelButtonPress: () => setQuery(""),
                onChangeText: (event) => setQuery(event.nativeEvent.text),
                placeholder: "Messages and tasks",
                placement: "automatic",
              }
            : undefined,
        }}
      />
      {!nativeSearch ? (
        <View style={[styles.searchWrap, { backgroundColor: theme.surface, borderBottomColor: theme.line }]}>
          <View style={[styles.searchBar, { backgroundColor: theme.input, borderColor: theme.line }]}>
            <Icon name={{ ios: "magnifyingglass", android: "search", web: "search" }} color={theme.faint} size={19} />
            <TextInput
              ref={input}
              accessibilityLabel="Search workspace"
              autoCapitalize="none"
              autoCorrect={false}
              autoFocus
              onChangeText={setQuery}
              placeholder="Messages and tasks"
              placeholderTextColor={theme.faint}
              returnKeyType="search"
              selectionColor={theme.accent}
              style={[styles.input, { color: theme.text }]}
              value={query}
            />
            {loading ? <ActivityIndicator color={theme.accent} size="small" /> : null}
            {query && !loading ? (
              <Pressable accessibilityRole="button" accessibilityLabel="Clear search" hitSlop={8} onPress={() => setQuery("")}>
                <Icon name={{ ios: "xmark.circle.fill", android: "cancel", web: "cancel" }} color={theme.faint} size={19} />
              </Pressable>
            ) : null}
          </View>
        </View>
      ) : null}

      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={styles.scroll}
        keyboardDismissMode="on-drag"
        keyboardShouldPersistTaps="handled"
      >
       <Measured>
        <ErrorNotice message={error} />
        {!query.trim() ? (
          <SearchPrompt
            icon={{ ios: "magnifyingglass", android: "search", web: "search" }}
            title="Search your workspace"
            detail="Find messages and tasks as you type."
          />
        ) : results && total === 0 && !loading ? (
          <SearchPrompt
            icon={{ ios: "doc.text.magnifyingglass", android: "search_off", web: "search_off" }}
            title="No results"
            detail={`Nothing matched “${query.trim()}”. Try a shorter phrase.`}
          />
        ) : results ? (
          <>
            {results.messages.length ? (
              <View style={styles.section}>
                <SectionTitle title="Messages" count={results.messages.length} />
                <View style={styles.resultGroup}>
                  {results.messages.map((hit) => (
                    <Pressable
                      accessibilityRole="button"
                      key={hit.message.id}
                      onPress={() => router.push({ pathname: "/channels/[channelId]", params: { channelId: hit.message.channel_id } })}
                      style={({ pressed }) => [styles.result, { borderBottomColor: theme.line }, pressed && styles.pressed]}
                    >
                      <View style={styles.resultIcon}>
                        <Icon name={{ ios: "bubble.left", android: "chat_bubble", web: "chat_bubble" }} color={theme.accent} size={18} />
                      </View>
                      <View style={styles.main}>
                        <Text numberOfLines={1} style={[styles.title, { color: theme.text }]}>{hit.author_name} in #{hit.channel_name}</Text>
                        <Text numberOfLines={3} style={[styles.snippet, { color: theme.muted }]}>{hit.snippet}</Text>
                        <Text style={[styles.meta, { color: theme.faint }]}>{relative(hit.message.created_at)}</Text>
                      </View>
                      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
                    </Pressable>
                  ))}
                </View>
              </View>
            ) : null}

            {results.tasks.length ? (
              <View style={styles.section}>
                <SectionTitle title="Tasks" count={results.tasks.length} />
                <View style={styles.resultGroup}>
                  {results.tasks.map((task) => (
                    <Pressable
                      accessibilityRole="button"
                      key={task.id}
                      onPress={() => router.push({ pathname: "/tasks/[taskId]", params: { taskId: task.id } })}
                      style={({ pressed }) => [styles.result, { borderBottomColor: theme.line }, pressed && styles.pressed]}
                    >
                      <View style={styles.resultIcon}>
                        <Icon name={{ ios: "checkmark.circle", android: "task_alt", web: "task_alt" }} color={theme.positive} size={19} />
                      </View>
                      <View style={styles.main}>
                        <Text numberOfLines={2} style={[styles.title, { color: theme.text }]}>{task.title}</Text>
                        {task.brief ? <Text numberOfLines={2} style={[styles.snippet, { color: theme.muted }]}>{task.brief}</Text> : null}
                      </View>
                      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
                    </Pressable>
                  ))}
                </View>
              </View>
            ) : null}
          </>
        ) : null}
       </Measured>
      </ScrollView>
    </Screen>
  );
}

function SectionTitle({ title, count }: { title: string; count: number }) {
  const theme = useTheme();
  return (
    <View style={styles.sectionTitleRow}>
      <Text style={[styles.sectionTitle, { color: theme.faint }]}>{title}</Text>
      <Text style={[styles.sectionCount, { color: theme.faint }]}>{count}</Text>
    </View>
  );
}

function SearchPrompt({ icon, title, detail }: { icon: Parameters<typeof Icon>[0]["name"]; title: string; detail: string }) {
  const theme = useTheme();
  return (
    <View style={styles.prompt}>
      <Glass radius={22} style={styles.promptIcon}>
        <Icon name={icon} color={theme.faint} size={30} />
      </Glass>
      <Text style={[styles.promptTitle, { color: theme.text }]}>{title}</Text>
      <Text style={[styles.promptDetail, { color: theme.muted }]}>{detail}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  searchWrap: { paddingHorizontal: 16, paddingVertical: 10, borderBottomWidth: StyleSheet.hairlineWidth },
  searchBar: { minHeight: 44, borderRadius: 12, borderWidth: StyleSheet.hairlineWidth, flexDirection: "row", alignItems: "center", gap: 9, paddingHorizontal: 12 },
  input: { flex: 1, minHeight: 42, paddingVertical: 8, fontSize: 16 },
  scroll: { flexGrow: 1, paddingBottom: 40 },
  section: { marginBottom: 22 },
  sectionTitleRow: { minHeight: 36, flexDirection: "row", alignItems: "center", gap: 7, paddingHorizontal: 16 },
  sectionTitle: { fontSize: 13, fontWeight: "600" },
  sectionCount: { fontSize: 12, fontWeight: "600" },
  resultGroup: { overflow: "hidden" },
  result: { minHeight: 76, flexDirection: "row", alignItems: "center", gap: 11, paddingHorizontal: 16, paddingVertical: 11, borderBottomWidth: StyleSheet.hairlineWidth },
  resultIcon: { width: 26, alignItems: "center", justifyContent: "center" },
  main: { flex: 1, minWidth: 0, gap: 4 },
  title: { fontSize: 15, fontWeight: "600", lineHeight: 20 },
  snippet: { fontSize: 14, lineHeight: 19 },
  meta: { fontSize: 11 },
  pressed: { opacity: 0.58 },
  prompt: { flex: 1, minHeight: 330, alignItems: "center", justifyContent: "center", paddingHorizontal: 28 },
  promptIcon: { width: 68, height: 68, alignItems: "center", justifyContent: "center", marginBottom: 16 },
  promptTitle: { fontSize: 19, fontWeight: "700", textAlign: "center" },
  promptDetail: { maxWidth: 420, fontSize: 15, lineHeight: 21, textAlign: "center", marginTop: 6 },
});
