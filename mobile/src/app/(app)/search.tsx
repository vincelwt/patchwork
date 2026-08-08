import { useState } from "react";
import { Alert, Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import type { SearchResults } from "@client/types";
import { Empty, Loading, PageHeader, ScrollScreen } from "@/components/ui";
import { useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function SearchScreen() {
  const colors = useTheme();
  const store = useWorkspaceStore();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults>();
  const [loading, setLoading] = useState(false);

  async function search() {
    if (!query.trim()) return;
    setLoading(true);
    try {
      setResults(await store.mutate((api) => api.search(query.trim()), false));
    } catch (error) {
      Alert.alert("Search failed", error instanceof Error ? error.message : String(error));
    } finally {
      setLoading(false);
    }
  }

  return (
    <ScrollScreen>
      <PageHeader back title="Search" />
      <View style={styles.form}>
        <TextInput
          accessibilityLabel="Search workspace"
          autoCapitalize="none"
          onChangeText={setQuery}
          onSubmitEditing={() => void search()}
          placeholder="Messages and tasks"
          placeholderTextColor={colors.muted}
          returnKeyType="search"
          style={[styles.input, { color: colors.text, borderColor: colors.line, backgroundColor: colors.input }]}
          value={query}
        />
        <Pressable accessibilityRole="button" onPress={() => void search()} style={[styles.button, { backgroundColor: colors.accent }]}>
          <Text style={[styles.buttonText, { color: colors.onAccent }]}>Search</Text>
        </Pressable>
      </View>
      {loading ? <Loading /> : null}
      {results ? (
        <>
          <Text style={[styles.section, { color: colors.muted }]}>Messages</Text>
          {results.messages.map((hit) => (
            <Pressable
              accessibilityRole="button"
              key={hit.message.id}
              onPress={() => router.push({ pathname: "/(app)/channels/[channelId]", params: { channelId: hit.message.channel_id } })}
              style={[styles.result, { borderColor: colors.line }]}
            >
              <Text style={[styles.title, { color: colors.text }]}>{hit.author_name} in {hit.channel_name}</Text>
              <Text numberOfLines={3} style={{ color: colors.muted }}>{hit.snippet}</Text>
            </Pressable>
          ))}
          {!results.messages.length ? <Empty title="No matching messages" /> : null}
          <Text style={[styles.section, { color: colors.muted }]}>Tasks</Text>
          {results.tasks.map((task) => (
            <Pressable
              accessibilityRole="button"
              key={task.id}
              onPress={() => router.push({ pathname: "/(app)/tasks/[taskId]", params: { taskId: task.id } })}
              style={[styles.result, { borderColor: colors.line }]}
            >
              <Text style={[styles.title, { color: colors.text }]}>{task.key} · {task.title || task.outcome}</Text>
              <Text style={{ color: colors.muted }}>{task.status.replace("_", " ")}</Text>
            </Pressable>
          ))}
          {!results.tasks.length ? <Empty title="No matching tasks" /> : null}
        </>
      ) : null}
    </ScrollScreen>
  );
}

const styles = StyleSheet.create({
  form: { flexDirection: "row", gap: 8 },
  input: { flex: 1, minHeight: 46, borderWidth: 1, borderRadius: 12, paddingHorizontal: 14, fontSize: 16 },
  button: { minHeight: 46, borderRadius: 12, justifyContent: "center", paddingHorizontal: 16 },
  buttonText: { fontWeight: "700" },
  result: { borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 14, gap: 4 },
  title: { fontWeight: "600" },
  section: { fontSize: 12, fontWeight: "700", letterSpacing: 0.7, marginTop: 20, textTransform: "uppercase" },
});
