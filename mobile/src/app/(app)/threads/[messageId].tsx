import { useEffect, useMemo } from "react";
import { FlatList, StyleSheet, View } from "react-native";
import { Stack, useLocalSearchParams } from "expo-router";

import { Composer } from "@/components/Composer";
import { MessageRow } from "@/components/Message";
import { Empty, Measured } from "@/components/ui";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useBottomAnchoredList } from "@/lib/scroll";
import type { Message } from "@client/types";

export default function ThreadScreen() {
  const { messageId } = useLocalSearchParams<{ messageId: string }>();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const root = useMemo(
    () => Object.values(workspace.messages).flat().find((message) => message.id === messageId),
    [messageId, workspace.messages],
  );
  const replies = workspace.threads[messageId] ?? [];
  const channel = workspace.bootstrap?.channels.find((item) => item.id === root?.channel_id);
  const anchor = useBottomAnchoredList<Message>(
    messageId,
    root ? replies.length + 1 : 0,
  );

  useEffect(() => {
    void store.loadThread(messageId);
  }, [messageId, store]);

  return (
    <View style={styles.fill}>
      <Stack.Screen options={{ title: "Thread", headerBackTitle: "Back" }} />
      {!root || !channel ? (
        <Empty title="Thread unavailable" detail="Open it from its conversation so the original message can be loaded." />
      ) : (
        <>
          <FlatList
            ref={anchor.listRef}
            data={replies}
            keyExtractor={(message) => message.id}
            ListHeaderComponent={<Measured style={styles.root}><MessageRow message={root} inThread /></Measured>}
            renderItem={({ item }) => <Measured><MessageRow message={item} inThread /></Measured>}
            contentInsetAdjustmentBehavior="automatic"
            contentContainerStyle={styles.list}
            onContentSizeChange={anchor.onContentSizeChange}
            onScroll={anchor.onScroll}
            onScrollBeginDrag={anchor.onScrollBeginDrag}
            onScrollEndDrag={anchor.onScrollEndDrag}
            onMomentumScrollBegin={anchor.onMomentumScrollBegin}
            onMomentumScrollEnd={anchor.onMomentumScrollEnd}
            scrollEventThrottle={16}
          />
          <Composer channelId={channel.id} parentId={messageId} taskId={channel.task_id} placeholder="Reply in thread" />
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  list: { paddingVertical: 8 },
  root: { paddingBottom: 12, marginBottom: 4 },
});
