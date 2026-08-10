import { useState } from "react";
import { StyleSheet, View } from "react-native";
import { Stack, useLocalSearchParams, useRouter } from "expo-router";

import { Conversation } from "@/components/Message";
import { Button, ChoiceField, ErrorNotice, Sheet, TextField } from "@/components/ui";
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
  const [sectionId, setSectionId] = useState(channel?.section_id ?? "");
  const [error, setError] = useState("");

  if (!channel) {
    return (
      <View style={styles.fill}>
        <Stack.Screen options={{ title: "Conversation", headerTransparent: false }} />
      </View>
    );
  }

  const save = async () => {
    try {
      await store.mutate((api) => api.updateChannel(channel.id, { name, topic, section_id: sectionId }));
      setEditing(false);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  };

  return (
    <View style={styles.fill}>
      <Stack.Screen
        options={{
          title: channel.kind === "channel" ? `# ${channel.name}` : channel.name,
          headerTransparent: false,
          headerRight: channel.kind === "channel"
            ? () => <Button label="Edit" compact tone="quiet" onPress={() => setEditing(true)} />
            : undefined,
        }}
      />
      <Conversation channelId={channel.id} />
      <Sheet visible={editing} title="Channel settings" onClose={() => setEditing(false)}>
        <View style={styles.form}>
          <TextField label="Name" value={name} onChangeText={setName} autoCapitalize="none" />
          <TextField label="Topic" value={topic} onChangeText={setTopic} multiline />
          {workspace.bootstrap?.sections.length ? (
            <ChoiceField
              label="Section"
              value={sectionId}
              options={[
                { value: "", label: "No section" },
                ...workspace.bootstrap.sections.map((section) => ({ value: section.id, label: section.name })),
              ]}
              onChange={setSectionId}
            />
          ) : null}
          <ErrorNotice message={error} />
          <Button label="Save" disabled={!name.trim()} onPress={() => void save()} />
          <Button
            label="Archive channel"
            tone="danger"
            onPress={async () => {
              await store.mutate((api) => api.archiveChannel(channel.id));
              router.replace("/channels");
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
