import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { Channel, Id } from "@client/types";
import { Conversation } from "@/components/Message";
import { Avatar, Button, ChoiceField, Empty, ErrorNotice, Glass, Icon, Measured, Sheet, TextField } from "@/components/ui";
import { relative } from "@/lib/format";
import { useLayout } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function ChannelsScreen() {
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const router = useRouter();
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const { split, gutter } = useLayout();
  const [newChannel, setNewChannel] = useState(false);
  const [newDm, setNewDm] = useState(false);
  const [name, setName] = useState("");
  const [topic, setTopic] = useState("");
  const [sectionId, setSectionId] = useState("");
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<Id>();
  const data = workspace.bootstrap;
  if (!data) return <Empty title="No workspace data yet" />;

  const inlineTitle = !split;
  const actions = (
    <View style={styles.actions}>
      <Pressable accessibilityRole="button" accessibilityLabel="New direct message" hitSlop={8} style={styles.action} onPress={() => setNewDm(true)}>
        <Icon name={{ ios: "person.badge.plus", android: "person_add", web: "person_add" }} color={theme.accent} size={21} />
      </Pressable>
      <Pressable accessibilityRole="button" accessibilityLabel="New channel" hitSlop={8} style={styles.action} onPress={() => setNewChannel(true)}>
        <Icon name={{ ios: "plus", android: "add", web: "add" }} color={theme.accent} size={23} />
      </Pressable>
    </View>
  );

  // On a wide screen the conversation opens beside the list instead of on top of it.
  const open = (channel: Channel) =>
    split
      ? setSelected(channel.id)
      : router.push({ pathname: "/channels/[channelId]", params: { channelId: channel.id } });
  const create = async () => {
    setError("");
    try {
      await store.mutate(
        (api) => api.createChannel({ name, topic, section_id: sectionId || undefined }),
        true,
        (channel) => {
          setNewChannel(false);
          setName("");
          setTopic("");
          setSectionId("");
          open(channel);
        },
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  const dms = data.channels.filter((channel) => channel.kind === "dm").sort((a, b) => b.last_message_at - a.last_message_at);
  const channels = data.channels.filter((channel) => channel.kind === "channel").sort((a, b) => a.position - b.position);
  const sectionIds = new Set(data.sections.map((section) => section.id));
  const unsectioned = channels.filter((channel) => !channel.section_id || !sectionIds.has(channel.section_id));
  const openChannel = selected ? data.channels.find((channel) => channel.id === selected) : undefined;

  const groups = (
    <>
      <ChannelGroup
        title="Channels"
        channels={unsectioned}
        onOpen={open}
        selected={split ? selected : undefined}
        // Only an empty workspace needs telling. With channels in sections, an
        // empty ungrouped heading is a wasted row saying something untrue.
        empty={channels.length ? undefined : "Create the first channel to get going."}
      />
      {data.sections.map((section) => (
        <ChannelGroup
          key={section.id}
          title={section.name}
          channels={channels.filter((channel) => channel.section_id === section.id)}
          onOpen={open}
          selected={split ? selected : undefined}
        />
      ))}
      <ChannelGroup
        title="Direct messages"
        channels={dms}
        onOpen={open}
        selected={split ? selected : undefined}
        empty="Start a direct conversation with a teammate."
      />
    </>
  );

  const list = (
    <ScrollView
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.scroll}
      showsVerticalScrollIndicator={!split}
    >
      {split ? (
        <>
          <Text style={[styles.paneTitle, { color: theme.text }]}>Chat</Text>
          {groups}
        </>
      ) : (
        <Measured>
          {inlineTitle ? (
            <View style={[styles.titleRow, { paddingTop: insets.top + 8 }]}>
              <Text accessibilityRole="header" style={[styles.title, { color: theme.text }]}>Chat</Text>
              <Glass interactive radius={24} style={styles.inlineActions}>{actions}</Glass>
            </View>
          ) : null}
          {groups}
        </Measured>
      )}
    </ScrollView>
  );

  return (
    <View style={[styles.fill, { backgroundColor: theme.surface }]}>
      <Stack.Screen
        options={{
          // UIKit cannot place bar buttons beside a large title, so the phone
          // draws that row itself and skips the otherwise-empty compact bar.
          headerShown: !inlineTitle,
          headerRight: inlineTitle ? undefined : () => actions,
        }}
      />
      {split ? (
        <View style={styles.split}>
          <View style={[styles.pane, { borderRightColor: theme.line }]}>{list}</View>
          <View style={[styles.detail, { backgroundColor: theme.surface }]}>
            {openChannel ? (
              <>
                <View style={[styles.detailHead, { borderBottomColor: theme.line, paddingHorizontal: gutter }]}>
                  <Text numberOfLines={1} style={[styles.detailTitle, { color: theme.text }]}>
                    {openChannel.kind === "channel" ? `# ${openChannel.name}` : openChannel.name}
                  </Text>
                  {openChannel.topic ? (
                    <Text numberOfLines={1} style={[styles.detailTopic, { color: theme.muted }]}>{openChannel.topic}</Text>
                  ) : null}
                </View>
                <Conversation channelId={openChannel.id} />
              </>
            ) : (
              <View style={styles.centre}>
                <Empty title="Pick a conversation" detail="Channels and direct messages open beside the list." />
              </View>
            )}
          </View>
        </View>
      ) : (
        list
      )}

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
                  await store.mutate(
                    (api) => api.openDm(member.id),
                    true,
                    (channel) => {
                      setNewDm(false);
                      open(channel);
                    },
                  );
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

/// An empty section is noise, so only the first group explains itself.
function ChannelGroup({
  title,
  channels,
  onOpen,
  selected,
  empty,
}: {
  title: string;
  channels: Channel[];
  onOpen: (channel: Channel) => void;
  selected?: Id;
  empty?: string;
}) {
  const theme = useTheme();
  if (!channels.length && !empty) return null;
  return (
    <View style={styles.group}>
      <View style={styles.sectionHead}>
        <Text style={[styles.section, { color: theme.faint }]}>{title}</Text>
        {channels.length ? <Text style={[styles.count, { color: theme.faint }]}>{channels.length}</Text> : null}
      </View>
      {channels.length ? (
        channels.map((channel) => (
          <ChannelRow
            key={channel.id}
            channel={channel}
            active={channel.id === selected}
            onPress={() => onOpen(channel)}
          />
        ))
      ) : (
        <Text style={[styles.groupEmpty, { color: theme.muted }]}>{empty}</Text>
      )}
    </View>
  );
}

function ChannelRow({ channel, active, onPress }: { channel: Channel; active?: boolean; onPress: () => void }) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected: active }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.channel,
        { borderBottomColor: theme.line },
        active && { backgroundColor: theme.accentSoft },
        pressed && { opacity: 0.6 },
      ]}
    >
      <View style={styles.channelIcon}>
        <Icon
          name={channel.kind === "dm" ? { ios: "person.crop.circle", android: "person", web: "person" } : { ios: "number", android: "tag", web: "tag" }}
          color={theme.accent}
          size={19}
        />
      </View>
      <View style={styles.fill}>
        <Text numberOfLines={1} style={[styles.channelName, { color: theme.text }]}>{channel.name}</Text>
        {channel.topic ? (
          <Text numberOfLines={1} style={[styles.channelTopic, { color: theme.muted }]}>{channel.topic}</Text>
        ) : null}
      </View>
      {channel.last_message_at ? <Text style={[styles.time, { color: theme.faint }]}>{relative(channel.last_message_at)}</Text> : null}
      <Icon name={{ ios: "chevron.right", android: "chevron_right", web: "chevron_right" }} color={theme.faint} size={15} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  titleRow: { minHeight: 64, flexDirection: "row", alignItems: "center", justifyContent: "space-between", paddingHorizontal: 16, paddingBottom: 8 },
  title: { fontSize: 34, fontWeight: "700", letterSpacing: -0.8 },
  actions: { flexDirection: "row", alignItems: "center" },
  action: { width: 36, height: 44, alignItems: "center", justifyContent: "center" },
  inlineActions: { height: 48, justifyContent: "center", paddingHorizontal: 4 },
  scroll: { paddingBottom: 30 },
  split: { flex: 1, flexDirection: "row" },
  pane: { width: 340, borderRightWidth: StyleSheet.hairlineWidth },
  paneTitle: { fontSize: 26, fontWeight: "700", letterSpacing: -0.6, paddingHorizontal: 16, paddingTop: 14, paddingBottom: 8 },
  detail: { flex: 1 },
  centre: { flex: 1, justifyContent: "center" },
  detailHead: { paddingTop: 13, paddingBottom: 11, borderBottomWidth: StyleSheet.hairlineWidth },
  detailTitle: { fontSize: 19, fontWeight: "700", letterSpacing: -0.3 },
  detailTopic: { fontSize: 13, marginTop: 2 },
  group: { marginBottom: 16 },
  sectionHead: { minHeight: 32, flexDirection: "row", alignItems: "center", gap: 7, paddingHorizontal: 16 },
  section: { fontSize: 13, fontWeight: "600" },
  count: { fontSize: 12, fontWeight: "600" },
  channel: { minHeight: 62, flexDirection: "row", alignItems: "center", gap: 11, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 9 },
  channelIcon: { width: 26, alignItems: "center", justifyContent: "center" },
  channelName: { fontSize: 16, fontWeight: "600" },
  channelTopic: { fontSize: 13, marginTop: 1 },
  time: { fontSize: 11 },
  groupEmpty: { paddingHorizontal: 16, paddingVertical: 9, fontSize: 13 },
  form: { padding: 16, gap: 14 },
  memberRow: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 11, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
});
