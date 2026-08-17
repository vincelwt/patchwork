import { useEffect, useMemo, useRef } from "react";
import { FlatList, StyleSheet, View } from "react-native";
import { Stack, useLocalSearchParams } from "expo-router";

import { Composer } from "@/components/Composer";
import { MessageRow } from "@/components/Message";
import { Empty, Measured } from "@/components/ui";
import { followNewest } from "@/lib/layout";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import type { Message } from "@client/types";

export default function ThreadScreen() {
  const { messageId } = useLocalSearchParams<{ messageId: string }>();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const list = useRef<FlatList<Message>>(null);
  const root = useMemo(
    () => Object.values(workspace.messages).flat().find((message) => message.id === messageId),
    [messageId, workspace.messages],
  );
  const replies = workspace.threads[messageId] ?? [];
  const channel = workspace.bootstrap?.channels.find((item) => item.id === root?.channel_id);
  // Newest reply first and drawn upside down, so the thread opens on the latest
  // reply without having to be scrolled there. The message the thread hangs off
  // is its oldest entry, which upside down is the list's footer.
  const newestFirst = useMemo(() => [...replies].reverse(), [replies]);

  useEffect(() => {
    void store.loadThread(messageId);
    if (!channel) return;
    return store.onMessageSent(channel.id, messageId, () =>
      requestAnimationFrame(() =>
        list.current?.scrollToOffset({ offset: 0, animated: true }),
      ),
    );
  }, [channel?.id, messageId, store]);

  return (
    <View style={styles.fill}>
      <Stack.Screen options={{ title: "Thread", headerBackTitle: "Back" }} />
      {!root || !channel ? (
        <Empty title="Thread unavailable" detail="Open it from its conversation so the original message can be loaded." />
      ) : (
        <>
          <FlatList
            ref={list}
            inverted
            data={newestFirst}
            keyExtractor={(message) => message.id}
            ListFooterComponent={<Measured style={styles.root}><MessageRow message={root} inThread /></Measured>}
            renderItem={({ item }) => <Measured><MessageRow message={item} inThread /></Measured>}
            contentInsetAdjustmentBehavior="automatic"
            contentContainerStyle={styles.list}
            maintainVisibleContentPosition={followNewest}
            keyboardDismissMode="interactive"
          />
          <Composer
            channelId={channel.id}
            parentId={messageId}
            taskId={channel.task_id}
            placeholder="Reply in thread"
          />
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  list: { paddingVertical: 8 },
  root: { paddingTop: 12, marginTop: 4 },
});
