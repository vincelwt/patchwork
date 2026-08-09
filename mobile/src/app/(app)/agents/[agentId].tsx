import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";

import { AgentEditor } from "@/components/AgentEditor";
import { Avatar, Badge, Button, Card, Empty, PageHeader, Sheet } from "@/components/ui";
import { relative, runStatusLabel } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function AgentScreen() {
  const { agentId } = useLocalSearchParams<{ agentId: string }>();
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const agent = data?.members.find((member) => member.id === agentId && member.kind === "agent");
  const [editing, setEditing] = useState(false);
  if (!agent || !data) return <Empty title="Agent unavailable" />;

  const profile = agent.agent!;
  const hosts = data.hosts.filter((host) =>
    host.capabilities.runtimes.some((runtime) => runtime.id === profile.runtime && runtime.available),
  );
  const runs = [
    ...data.active_runs.filter((run) => run.agent_id === agent.id),
    ...Object.values(workspace.runDetails).map((detail) => detail.run).filter((run) => run.agent_id === agent.id && !data.active_runs.some((active) => active.id === run.id)),
  ].sort((a, b) => b.created_at - a.created_at).slice(0, 10);

  const message = async () => {
    const channel = await store.mutate((api) => api.openDm(agent.id));
    router.push({ pathname: "/channels/[channelId]", params: { channelId: channel.id } });
  };

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader title={agent.display_name} subtitle={`@${agent.handle}`} back action={<Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} />} />
      <ScrollView contentContainerStyle={styles.scroll}>
        <View style={styles.hero}>
          <Avatar member={agent} size={64} />
          <View style={styles.fill}>
            <Text style={[styles.name, { color: theme.text }]}>{agent.display_name}</Text>
            <Text style={[styles.description, { color: theme.muted }]}>{profile.description || "No ownership description yet."}</Text>
          </View>
        </View>
        <View style={styles.actions}>
          <Button label="Message agent" onPress={() => void message()} />
          {runs.find((run) => !["succeeded", "failed", "cancelled"].includes(run.status)) ? (
            <Button
              label="Open active run"
              tone="secondary"
              onPress={() => {
                const run = runs.find((item) => !["succeeded", "failed", "cancelled"].includes(item.status));
                if (run) router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } });
              }}
            />
          ) : null}
        </View>
        <Card style={styles.card}>
          <Info label="Runtime" value={profile.runtime} />
          <Info label="Placement" value={profile.location === "desktop" ? data.hosts.find((host) => host.id === profile.host_id)?.name || "Desktop" : profile.location} />
          <Info label="Model" value={profile.model || "Machine default"} />
          <Info label="Participation" value={profile.default_participation} />
          <Info label="Direct messages" value={profile.dm_enabled ? "Enabled" : "Off"} />
        </Card>
        <Text style={[styles.section, { color: theme.faint }]}>AVAILABLE HOSTS</Text>
        <Card>
          {hosts.map((host) => (
            <View key={host.id} style={[styles.hostRow, { borderBottomColor: theme.line }]}>
              <View style={styles.fill}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{host.name}</Text>
                <Text style={{ color: theme.muted }}>{host.kind === "desktop" ? "Desktop agent host" : "Relay agent host"}</Text>
              </View>
              <Badge tone={host.online ? "positive" : "neutral"}>{host.online ? "online" : "offline"}</Badge>
            </View>
          ))}
          {!hosts.length ? <Empty title="No compatible host" detail="Connect a Desktop that exposes this runtime or install it on the relay." /> : null}
        </Card>
        <Text style={[styles.section, { color: theme.faint }]}>RECENT RUNS</Text>
        <Card>
          {runs.map((run) => (
            <Pressable key={run.id} onPress={() => router.push({ pathname: "/(app)/runs/[runId]", params: { runId: run.id } })} style={[styles.runRow, { borderBottomColor: theme.line }]}>
              <View style={styles.fill}>
                <Text numberOfLines={1} style={{ color: theme.text, fontWeight: "600" }}>{run.headline || run.prompt}</Text>
                <Text style={{ color: theme.muted }}>{relative(run.created_at)}</Text>
              </View>
              <Badge tone={run.status === "failed" ? "danger" : run.status === "waiting" ? "caution" : run.status === "succeeded" ? "positive" : "accent"}>{runStatusLabel(run.status)}</Badge>
            </Pressable>
          ))}
          {!runs.length ? <Empty title="No runs loaded" /> : null}
        </Card>
      </ScrollView>
      <Sheet visible={editing} title={`Edit ${agent.display_name}`} onClose={() => setEditing(false)}>
        <AgentEditor agent={agent} onSaved={() => setEditing(false)} />
      </Sheet>
    </View>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  const theme = useTheme();
  return <View style={styles.info}><Text style={{ color: theme.muted }}>{label}</Text><Text style={{ color: theme.text, fontWeight: "600", textTransform: "capitalize" }}>{value}</Text></View>;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { padding: 16, gap: 14, paddingBottom: 32 },
  hero: { flexDirection: "row", gap: 14, alignItems: "center" },
  name: { fontSize: 23, fontWeight: "700" },
  description: { fontSize: 14, lineHeight: 20, marginTop: 4 },
  actions: { flexDirection: "row", flexWrap: "wrap", gap: 8 },
  card: { padding: 14, gap: 10 },
  info: { flexDirection: "row", justifyContent: "space-between", gap: 12 },
  section: { fontSize: 11, fontWeight: "700", letterSpacing: 0.8, marginTop: 4 },
  hostRow: { minHeight: 58, padding: 12, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth },
  runRow: { minHeight: 62, padding: 12, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth },
});
