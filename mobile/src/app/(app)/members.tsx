import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import type { Member } from "@client/types";
import { Avatar, Badge, Button, Empty, ErrorNotice, Grouped, Sheet, TextField, ToggleRow } from "@/components/ui";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function MembersScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const [inviting, setInviting] = useState(false);
  const [email, setEmail] = useState("");
  const [admin, setAdmin] = useState(false);
  const [invite, setInvite] = useState("");
  const [removing, setRemoving] = useState<Member>();
  const [error, setError] = useState("");
  if (!data) return <Empty title="Loading members" />;

  const dm = async (member: Member) => {
    await store.mutate(
      (api) => api.openDm(member.id),
      true,
      (channel) => router.push({ pathname: "/channels/[channelId]", params: { channelId: channel.id } }),
    );
  };

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen
        options={{
          title: "Members",
          headerRight: data.me.is_admin
            ? () => <Button label="Invite" compact tone="quiet" onPress={() => setInviting(true)} />
            : undefined,
        }}
      />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
       <Grouped>
        {data.members.map((member) => (
          <Pressable
            key={member.id}
            disabled={member.id === data.me.id}
            onPress={() => void dm(member)}
            style={({ pressed }) => [styles.row, { borderBottomColor: theme.line }, pressed && { opacity: 0.6 }]}
          >
            <Avatar member={member} />
            <View style={styles.main}>
              <Text style={[styles.name, { color: theme.text }]}>{member.display_name}{member.id === data.me.id ? " (you)" : ""}</Text>
              <Text style={{ color: theme.muted }}>@{member.handle}{member.kind === "agent" ? ` · ${member.agent?.runtime}` : ""}</Text>
            </View>
            {member.is_admin ? <Badge>admin</Badge> : null}
            <Badge tone={member.presence === "online" || member.presence === "working" ? "positive" : member.presence === "waiting" ? "caution" : "neutral"}>{member.presence}</Badge>
            {data.me.is_admin && member.id !== data.me.id ? <Button label="Remove" compact tone="quiet" onPress={() => setRemoving(member)} /> : null}
          </Pressable>
        ))}
       </Grouped>
      </ScrollView>

      <Sheet visible={inviting} title="Invite someone" onClose={() => { setInviting(false); setInvite(""); }}>
        <View style={styles.form}>
          {invite ? (
            <>
              <Text style={{ color: theme.text, fontWeight: "700" }}>Send this one-use invite code with the relay URL:</Text>
              <Text selectable style={[styles.code, { color: theme.accent, backgroundColor: theme.code }]}>{invite}</Text>
              <Text style={{ color: theme.muted }}>This creates a new workspace member. Pairing another device for yourself happens from Desktop.</Text>
            </>
          ) : (
            <>
              <TextField label="Email (optional)" value={email} onChangeText={setEmail} keyboardType="email-address" autoCapitalize="none" />
              <ToggleRow label="Workspace admin" value={admin} onChange={setAdmin} />
              <ErrorNotice message={error} />
              <Button label="Create invite" onPress={async () => { try { await store.mutate((api) => api.createInvite({ email: email.trim() || undefined, is_admin: admin }), false, (result) => setInvite(result.code)); } catch (caught) { setError(caught instanceof Error ? caught.message : String(caught)); } }} />
            </>
          )}
        </View>
      </Sheet>

      <Sheet visible={!!removing} title={`Remove ${removing?.display_name ?? "member"}?`} onClose={() => setRemoving(undefined)}>
        <View style={styles.form}>
          <Text style={{ color: theme.muted, lineHeight: 21 }}>They lose access immediately. Their messages remain in the workspace record.</Text>
          <Button label="Remove member" tone="danger" onPress={async () => { if (!removing) return; await store.mutate((api) => api.removeMember(removing.id)); setRemoving(undefined); }} />
        </View>
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  scroll: { paddingBottom: 30 },
  row: { minHeight: 68, flexDirection: "row", alignItems: "center", gap: 10, borderBottomWidth: StyleSheet.hairlineWidth, paddingHorizontal: 16, paddingVertical: 10 },
  main: { flex: 1, minWidth: 0 },
  name: { fontSize: 15, fontWeight: "700", marginBottom: 2 },
  form: { padding: 18, gap: 15 },
  code: { borderRadius: 10, padding: 14, fontSize: 17, fontWeight: "700" },
});
