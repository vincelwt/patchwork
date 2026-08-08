import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { useRouter } from "expo-router";

import type { Channel } from "@client/types";
import { Avatar, Button, Empty, ErrorNotice, PageHeader, Sheet, TextField } from "@/components/ui";
import { relative } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function ChannelsScreen() {
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const router = useRouter();
  const theme = useTheme();
  const [newChannel, setNewChannel] = useState(false);
  const [newDm, setNewDm] = useState(false);
  const [name, setName] = useState("");
  const [topic, setTopic] = useState("");
  const [error, setError] = useState("");
  const data = workspace.bootstrap;
  if (!data) return <Empty title="No workspace data yet" />;

  const open = (channel: Channel) => router.push({ pathname: "/(app)/channels/[channelId]", params: { channelId: channel.id } });
  const create = async () => {
    setError("");
    try {
      const channel = await store.mutate((api) => api.createChannel({ name, topic }));
      setNewChannel(false);
      setName("");
      setTopic("");
      open(channel);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  const dms = data.channels.filter((channel) => channel.kind === "dm");
  const channels = data.channels.filter((channel) => channel.kind === "channel");

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <PageHeader
        title="Chat"
        subtitle={`${channels.length} channels · ${dms.length} direct`}
        action={<View style={styles.actions}><Button label="DM" compact tone="quiet" onPress={() => setNewDm(true)} /><Button label="New" compact onPress={() => setNewChannel(true)} /></View>}
      />
      <ScrollView contentContainerStyle={styles.scroll}>
        <SectionTitle title="Channels" />
        {channels.length ? channels.map((channel) => <ChannelRow key={channel.id} channel={channel} onPress={() => open(channel)} />) : <Empty title="No channels" />}
        <SectionTitle title="Direct messages" />
        {dms.length ? dms.map((channel) => <ChannelRow key={channel.id} channel={channel} onPress={() => open(channel)} />) : <Text style={{ color: theme.muted }}>Start a direct conversation with a person or agent.</Text>}
      </ScrollView>

      <Sheet visible={newChannel} title="New channel" onClose={() => setNewChannel(false)}>
        <View style={styles.form}>
          <TextField label="Name" value={name} onChangeText={setName} autoCapitalize="none" />
          <TextField label="Topic" value={topic} onChangeText={setTopic} multiline />
          <ErrorNotice message={error} />
          <Button label="Create channel" disabled={!name.trim()} onPress={() => void create()} />
        </View>
      </Sheet>

      <Sheet visible={newDm} title="New direct message" onClose={() => setNewDm(false)}>
        <ScrollView>
          {data.members.filter((member) => member.id !== data.me.id).map((member) => (
            <Pressable
              key={member.id}
              style={[styles.memberRow, { borderBottomColor: theme.line }]}
              onPress={async () => {
                try {
                  const channel = await store.mutate((api) => api.openDm(member.id));
                  setNewDm(false);
                  open(channel);
                } catch (caught) {
                  setError(caught instanceof Error ? caught.message : String(caught));
                }
              }}
            >
              <Avatar member={member} />
              <View style={styles.fill}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{member.display_name}</Text>
                <Text style={{ color: theme.muted }}>@{member.handle}{member.kind === "agent" ? " · agent" : ""}</Text>
              </View>
            </Pressable>
          ))}
        </ScrollView>
      </Sheet>
    </View>
  );
}

function SectionTitle({ title }: { title: string }) {
  const theme = useTheme();
  return <Text style={[styles.section, { color: theme.faint }]}>{title}</Text>;
}

function ChannelRow({ channel, onPress }: { channel: Channel; onPress: () => void }) {
  const theme = useTheme();
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [styles.channel, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}>
      <Text style={[styles.hash, { color: theme.accent }]}>{channel.kind === "dm" ? "↔" : "#"}</Text>
      <View style={styles.fill}>
        <Text numberOfLines={1} style={[styles.channelName, { color: theme.text }]}>{channel.name}</Text>
        <Text numberOfLines={1} style={{ color: theme.muted }}>{channel.topic || "No topic"}</Text>
      </View>
      {channel.last_message_at ? <Text style={[styles.time, { color: theme.faint }]}>{relative(channel.last_message_at)}</Text> : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  actions: { flexDirection: "row", gap: 6 },
  scroll: { padding: 16, paddingBottom: 30 },
  section: { fontSize: 12, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.7, marginTop: 14, marginBottom: 5 },
  channel: { minHeight: 64, flexDirection: "row", alignItems: "center", gap: 11, borderBottomWidth: StyleSheet.hairlineWidth, paddingVertical: 9 },
  hash: { width: 28, textAlign: "center", fontSize: 22, fontWeight: "600" },
  channelName: { fontSize: 16, fontWeight: "600", marginBottom: 2 },
  time: { fontSize: 11 },
  form: { padding: 16, gap: 14 },
  memberRow: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 11, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
});
