import { Linking, Pressable, StyleSheet, Text } from "react-native";

import type { Task } from "@client/types";
import { pullRequestLabel } from "@/lib/format";
import { useTheme } from "@/lib/theme";

type PullRequestTask = Pick<Task, "pr_url" | "pr_state">;

export function PullRequestLink({ task }: { task: PullRequestTask }) {
  const theme = useTheme();
  const url = task.pr_url;
  if (!url) return null;

  const label = pullRequestLabel(task);
  return (
    <Pressable
      accessibilityLabel={`Open ${label}`}
      accessibilityRole="link"
      hitSlop={6}
      onPress={(event) => {
        event.stopPropagation();
        void Linking.openURL(url);
      }}
      style={({ pressed }) => [
        styles.link,
        { backgroundColor: theme.accentSoft },
        pressed && styles.pressed,
      ]}
    >
      <Text numberOfLines={1} style={[styles.label, { color: theme.accent }]}>
        {label} ↗
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  link: {
    minHeight: 32,
    alignSelf: "flex-start",
    justifyContent: "center",
    borderRadius: 999,
    paddingHorizontal: 9,
    paddingVertical: 4,
  },
  label: { fontSize: 12, fontWeight: "700" },
  pressed: { opacity: 0.58 },
});
