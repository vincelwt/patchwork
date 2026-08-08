import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";

import { Conversation } from "@/components/Message";
import { Button, ErrorNotice, PageHeader, Sheet, TextField } from "@/components/ui";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";

export default function ChannelScreen() {
  const { channelId } = useLocalSearchParams<{ channelId: string }>();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const channel = workspace.bootstrap?.channels.find((item) => item.id === channelId);
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(channel?.name ?? "");
  const [topic, setTopic] = useState(channel?.topic ?? "");
  const [error, setError] = useState("");

  if (!channel) return <View style={styles.fill}><PageHeader title="Conversation" back /></View>;

  const save = async () => {
    try {
      await store.mutate((api) => api.updateChannel(channel.id, { name, topic }));
      setEditing(false);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  return (
    <View style={styles.fill}>
      <PageHeader
        title={channel.kind === "channel" ? `# ${channel.name}` : channel.name}
        subtitle={channel.topic || (channel.kind === "dm" ? "Direct message" : undefined)}
        back
        action={channel.kind === "channel" ? <Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} /> : undefined}
      />
      <Conversation channelId={channel.id} />
      <Sheet visible={editing} title="Channel settings" onClose={() => setEditing(false)}>
        <View style={styles.form}>
          <TextField label="Name" value={name} onChangeText={setName} autoCapitalize="none" />
          <TextField label="Topic" value={topic} onChangeText={setTopic} multiline />
          <ErrorNotice message={error} />
          <Button label="Save" disabled={!name.trim()} onPress={() => void save()} />
          <Button
            label="Archive channel"
            tone="danger"
            onPress={async () => {
              await store.mutate((api) => api.archiveChannel(channel.id));
              router.replace("/(app)/channels");
            }}
          />
        </View>
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  form: { padding: 16, gap: 14 },
});
