import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import { AgentEditor } from "@/components/AgentEditor";
import { Avatar, Badge, Button, Empty, Grouped, Icon, Sheet } from "@/components/ui";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AgentsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const data = useWorkspace().bootstrap;
  const [creating, setCreating] = useState(false);
  const agents = data?.members.filter((member) => member.kind === "agent") ?? [];
  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen
        options={{
          title: "Agents",
          headerRight: () => <Button label="New" compact tone="quiet" onPress={() => setCreating(true)} />,
        }}
      />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
       <Grouped>
        {agents.length ? (
          <View style={styles.group}>
            {agents.map((agent) => {
              const host = data?.hosts.find((item) => item.id === agent.agent?.host_id);
              return (
                <Pressable
                  key={agent.id}
                  onPress={() => router.push({ pathname: "/(app)/agents/[agentId]", params: { agentId: agent.id } })}
                  style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
                >
                  <Avatar member={agent} size={38} />
                  <View style={styles.main}>
                    <Text style={[styles.name, { color: theme.text }]}>{agent.display_name}</Text>
                    <Text numberOfLines={2} style={[styles.description, { color: theme.muted }]}>{agent.agent?.description || `@${agent.handle}`}</Text>
                  </View>
                  <View style={styles.badges}>
                    <Badge tone={agent.presence === "working" ? "accent" : agent.presence === "waiting" ? "caution" : agent.presence === "online" ? "positive" : "neutral"}>{agent.presence}</Badge>
                    <Text numberOfLines={1} style={[styles.runtime, { color: theme.faint }]}>{host?.name || agent.agent?.runtime}</Text>
                  </View>
                  <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
                </Pressable>
              );
            })}
          </View>
        ) : null}
        {!agents.length ? <Empty title="No agents yet" detail="Create an agent teammate and choose where it runs." /> : null}
       </Grouped>
      </ScrollView>
      <Sheet visible={creating} title="New agent" onClose={() => setCreating(false)}>
        <AgentEditor
          onSaved={(agent) => {
            setCreating(false);
            router.push({ pathname: "/(app)/agents/[agentId]", params: { agentId: agent.id } });
          }}
        />
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { paddingBottom: 30 },
  group: { overflow: "hidden" },
  row: { minHeight: 78, flexDirection: "row", alignItems: "center", gap: 11, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 11 },
  main: { flex: 1, minWidth: 0 },
  name: { fontSize: 16, fontWeight: "700", marginBottom: 3 },
  description: { fontSize: 13, lineHeight: 18 },
  badges: { alignItems: "flex-end", gap: 5 },
  runtime: { fontSize: 11, maxWidth: 110 },
});
