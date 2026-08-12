import { useEffect, useState } from "react";
import { Alert, Linking, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Stack, useRouter } from "expo-router";

import type { Device } from "@client/types";
import { Badge, Button, Card, ErrorNotice, Measured, Sheet, TextField } from "@/components/ui";
import { relative } from "@/lib/format";
import { apiFor, usePairedSession } from "@/lib/session";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { useTheme } from "@/lib/theme";

export default function SettingsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const { session, workspaces, signOut } = usePairedSession();
  const data = workspace.bootstrap;
  const [devices, setDevices] = useState<Device[]>([]);
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(data?.workspace.name ?? "");
  const [prefix, setPrefix] = useState(data?.workspace.task_prefix ?? "PW");
  const [error, setError] = useState("");
  const [signingOut, setSigningOut] = useState(false);

  const loadDevices = async () => {
    try {
      await store.mutate((api) => api.devices(), false, setDevices);
    } catch {
      setDevices([]);
    }
  };
  useEffect(() => {
    if (workspace.connection === "live") void loadDevices();
  }, [workspace.connection]);

  return (
    <View style={[styles.fill, { backgroundColor: theme.bg }]}>
      <Stack.Screen options={{ title: "Settings" }} />
      <ScrollView contentInsetAdjustmentBehavior="automatic" contentContainerStyle={styles.scroll}>
       <Measured style={styles.measured}>
        {/* Switching workspaces lives on the More tab, whose icon is the one
            you are in; this screen is about the workspace already open. */}
        <Text style={[styles.section, { color: theme.faint }]}>This workspace</Text>
        <Card style={styles.card}>
          <Info label="Name" value={data?.workspace.name || "Loading"} />
          <Info label="Task prefix" value={data?.workspace.task_prefix || ""} />
          <Info label="Relay" value={session?.baseUrl || ""} selectable />
          <Info label="Connection" value={workspace.connection} />
          <Info label="Last sync" value={workspace.lastSyncAt ? relative(workspace.lastSyncAt) : "Not yet"} />
          {data?.me.is_admin ? <Button label="Edit workspace" tone="secondary" onPress={() => setEditing(true)} /> : null}
        </Card>
        <Text style={[styles.section, { color: theme.faint }]}>Your devices</Text>
        <Card>
          {devices.map((device) => (
            <View key={device.id} style={[styles.device, { borderBottomColor: theme.line }]}>
              <View style={styles.grow}>
                <Text style={{ color: theme.text, fontWeight: "600" }}>{device.label || "Unnamed device"}</Text>
                <Text style={{ color: theme.muted }}>{device.last_used ? `Used ${relative(device.last_used)}` : `Added ${relative(device.created_at)}`}</Text>
              </View>
              {device.current ? <Badge tone="positive">this device</Badge> : <Button label="Revoke" compact tone="danger" onPress={async () => { await store.mutate((api) => api.revokeDevice(device.id), false); await loadDevices(); }} />}
            </View>
          ))}
          {!devices.length ? <Text style={{ color: theme.muted, padding: 14 }}>Connect to load paired devices.</Text> : null}
        </Card>
        <Text style={[styles.section, { color: theme.faint }]}>About</Text>
        <Card style={styles.card}>
          <Button label="Privacy policy" tone="secondary" onPress={() => void Linking.openURL("https://patchwork.sh/privacy.html")} />
          <Button label="Support" tone="secondary" onPress={() => void Linking.openURL("https://patchwork.sh/support.html")} />
        </Card>
        <ErrorNotice message={error} />
        <Button
          label={workspaces.length > 1 ? "Sign out of this workspace" : "Sign out this device"}
          tone="danger"
          busy={signingOut}
          onPress={async () => {
            if (!session) return;
            setSigningOut(true);
            const revocation = workspace.connection === "live" && session
              ? Promise.race([
                  apiFor(session).revokeCurrentDevice().then(() => ""),
                  new Promise<string>((resolve) => setTimeout(
                    () => resolve("The device key could not be confirmed as revoked. Revoke it from another signed-in device."),
                    5_000,
                  )),
                ]).catch((caught) => `The device key could not be revoked: ${caught instanceof Error ? caught.message : String(caught)}`)
              : Promise.resolve("The workspace could not be reached, so this device key may still be active. Revoke it from another signed-in device.");
            let localWarning = "";
            try {
              await store.clearLocalData(session);
            } catch (caught) {
              localWarning = `Some saved workspace data could not be removed. Delete Patchwork before sharing this device: ${caught instanceof Error ? caught.message : String(caught)}`;
            }
            let removed = false;
            let secureWarning = "";
            try {
              removed = await signOut(session);
            } catch (caught) {
              secureWarning = `Patchwork could not remove this device's secure credential. Try again before sharing the device: ${caught instanceof Error ? caught.message : String(caught)}`;
            }
            const warning = [localWarning, await revocation].filter(Boolean).join("\n\n");
            if (secureWarning) {
              Alert.alert("Could not sign out", [secureWarning, warning].filter(Boolean).join("\n\n"));
              setSigningOut(false);
              return;
            }
            if (!removed) {
              if (warning) Alert.alert("Previous session cleanup incomplete", warning);
              setSigningOut(false);
              return;
            }
            router.replace("/");
            if (warning) Alert.alert("Signed out on this device", warning);
          }}
        />
       </Measured>
      </ScrollView>
      <Sheet visible={editing} title="Workspace" onClose={() => setEditing(false)}>
        <View style={styles.form}>
          <TextField label="Name" value={name} onChangeText={setName} />
          <TextField label="Task prefix" value={prefix} onChangeText={(value) => setPrefix(value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8))} autoCapitalize="characters" />
          <Button label="Save" onPress={async () => { try { await store.mutate((api) => api.updateWorkspace({ name: name.trim(), task_prefix: prefix })); setEditing(false); } catch (caught) { setError(caught instanceof Error ? caught.message : String(caught)); } }} />
        </View>
      </Sheet>
    </View>
  );
}

function Info({ label, value, selectable }: { label: string; value: string; selectable?: boolean }) {
  const theme = useTheme();
  return (
    <View style={styles.info}>
      <Text style={{ color: theme.muted }}>{label}</Text>
      <Text selectable={selectable} style={[styles.infoValue, { color: theme.text }]}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  grow: { flex: 1 },
  scroll: { padding: 16, paddingBottom: 36 },
  measured: { gap: 12 },
  section: { fontSize: 13, fontWeight: "600", marginTop: 8 },
  card: { padding: 14, gap: 11 },
  info: { flexDirection: "row", gap: 12, justifyContent: "space-between" },
  infoValue: { flex: 1, textAlign: "right", fontWeight: "600" },
  device: { minHeight: 60, flexDirection: "row", alignItems: "center", gap: 10, padding: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  form: { padding: 18, gap: 15 },
});
