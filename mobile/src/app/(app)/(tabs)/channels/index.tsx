import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import type { Channel } from "@client/types";
import { Avatar, Button, ChoiceField, Empty, ErrorNotice, Icon, Sheet, TextField } from "@/components/ui";
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
  const [sectionId, setSectionId] = useState("");
  const [error, setError] = useState("");
  const data = workspace.bootstrap;
  if (!data) return <Empty title="No workspace data yet" />;

  const open = (channel: Channel) => router.push({ pathname: "/channels/[channelId]", params: { channelId: channel.id } });
  const create = async () => {
    setError("");
    try {
      const channel = await store.mutate((api) => api.createChannel({ name, topic, section_id: sectionId || undefined }));
      setNewChannel(false);
      setName("");
      setTopic("");
      setSectionId("");
      open(channel);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  const dms = data.channels.filter((channel) => channel.kind === "dm").sort((a, b) => b.last_message_at - a.last_message_at);
  const channels = data.channels.filter((channel) => channel.kind === "channel").sort((a, b) => a.position - b.position);
  const sectionIds = new Set(data.sections.map((section) => section.id));
  const unsectioned = channels.filter((channel) => !channel.section_id || !sectionIds.has(channel.section_id));

  return (
    <View style={[styles.fill, { backgroundColor: theme.surface }]}>
      <Stack.Screen
        options={{
          headerRight: () => (
            <View style={styles.actions}>
              <Pressable accessibilityRole="button" accessibilityLabel="New direct message" hitSlop={8} onPress={() => setNewDm(true)}>
                <Icon name={{ ios: "person.badge.plus", android: "person_add", web: "person_add" }} color={theme.accent} size={21} />
              </Pressable>
              <Pressable accessibilityRole="button" accessibilityLabel="New channel" hitSlop={8} onPress={() => setNewChannel(true)}>
                <Icon name={{ ios: "plus", android: "add", web: "add" }} color={theme.accent} size={23} />
              </Pressable>
            </View>
          ),
        }}
      />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
        {unsectioned.length || !data.sections.length ? (
          <ChannelGroup title={data.sections.length ? "Other channels" : "Channels"} channels={unsectioned} onOpen={open} />
        ) : null}
        {data.sections.map((section) => (
          <ChannelGroup
            key={section.id}
            title={section.name}
            channels={channels.filter((channel) => channel.section_id === section.id)}
            onOpen={open}
          />
        ))}
        <ChannelGroup title="Direct messages" channels={dms} onOpen={open} empty="Start a direct conversation with a teammate." />
      </ScrollView>

      <Sheet visible={newChannel} title="New channel" onClose={() => setNewChannel(false)}>
        <View style={styles.form}>
          <TextField label="Name" value={name} onChangeText={setName} autoCapitalize="none" />
          <TextField label="Topic" value={topic} onChangeText={setTopic} multiline />
          {data.sections.length ? (
            <ChoiceField
              label="Section"
              value={sectionId}
              options={[{ value: "", label: "No section" }, ...data.sections.map((section) => ({ value: section.id, label: section.name }))]}
              onChange={setSectionId}
            />
          ) : null}
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

function ChannelGroup({
  title,
  channels,
  onOpen,
  empty = "No channels in this section.",
}: {
  title: string;
  channels: Channel[];
  onOpen: (channel: Channel) => void;
  empty?: string;
}) {
  const theme = useTheme();
  return (
    <View style={styles.group}>
      <View style={styles.sectionHead}>
        <Text style={[styles.section, { color: theme.faint }]}>{title}</Text>
        <Text style={[styles.count, { color: theme.faint }]}>{channels.length}</Text>
      </View>
      {channels.length ? (
        <View style={styles.channelGroup}>
          {channels.map((channel) => <ChannelRow key={channel.id} channel={channel} onPress={() => onOpen(channel)} />)}
        </View>
      ) : (
        <Text style={[styles.groupEmpty, { color: theme.muted }]}>{empty}</Text>
      )}
    </View>
  );
}

function ChannelRow({ channel, onPress }: { channel: Channel; onPress: () => void }) {
  const theme = useTheme();
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [styles.channel, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}>
      <View style={styles.channelIcon}>
        <Icon
          name={channel.kind === "dm" ? { ios: "person.crop.circle", android: "person", web: "person" } : { ios: "number", android: "tag", web: "tag" }}
          color={theme.accent}
          size={19}
        />
      </View>
      <View style={styles.fill}>
        <Text numberOfLines={1} style={[styles.channelName, { color: theme.text }]}>{channel.name}</Text>
        <Text numberOfLines={1} style={{ color: theme.muted }}>{channel.topic || "No topic"}</Text>
      </View>
      {channel.last_message_at ? <Text style={[styles.time, { color: theme.faint }]}>{relative(channel.last_message_at)}</Text> : null}
      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  actions: { flexDirection: "row", alignItems: "center", gap: 18 },
  scroll: { paddingBottom: 30 },
  group: { marginBottom: 18 },
  sectionHead: { minHeight: 34, flexDirection: "row", alignItems: "center", gap: 7, paddingHorizontal: 16 },
  section: { fontSize: 12, fontWeight: "700", textTransform: "uppercase", letterSpacing: 0.7 },
  count: { fontSize: 12, fontWeight: "600" },
  channelGroup: { overflow: "hidden" },
  channel: { minHeight: 66, flexDirection: "row", alignItems: "center", gap: 11, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 9 },
  channelIcon: { width: 28, alignItems: "center", justifyContent: "center" },
  channelName: { fontSize: 16, fontWeight: "600", marginBottom: 2 },
  time: { fontSize: 11 },
  groupEmpty: { paddingHorizontal: 16, paddingVertical: 9, fontSize: 13 },
  form: { padding: 16, gap: 14 },
  memberRow: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 11, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
});
