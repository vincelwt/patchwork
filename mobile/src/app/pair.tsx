import { useEffect, useRef, useState } from "react";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import { CameraView, useCameraPermissions } from "expo-camera";
import { useLocalSearchParams, useRouter } from "expo-router";
import { SafeAreaView } from "react-native-safe-area-context";

import type { Member, Workspace } from "@client/types";
import { Button, ErrorNotice, PageHeader } from "@/components/ui";
import { usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";

interface PairResponse {
  token: string;
  member: Member;
  workspace: Workspace;
}

export default function PairDevice() {
  const theme = useTheme();
  const router = useRouter();
  const params = useLocalSearchParams<{ base?: string; secret?: string }>();
  const { pair } = usePairedSession();
  const [permission, requestPermission] = useCameraPermissions();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const scanned = useRef(false);

  const claim = async (base: string, secret: string) => {
    if (busy || scanned.current) return;
    scanned.current = true;
    setBusy(true);
    setError("");
    try {
      const url = new URL(base);
      if (url.protocol !== "https:" && !__DEV__) throw new Error("Pairing requires an HTTPS relay.");
      if (!/\/w\/[^/]+\/?$/.test(url.pathname)) throw new Error("That code does not name a Patchwork workspace.");
      const response = await fetch(`${url.toString().replace(/\/$/, "")}/api/auth/pair`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ secret, device_name: deviceLabel() }),
      });
      const body = (await response.json().catch(() => null)) as PairResponse | { error?: { message?: string } } | null;
      if (!response.ok || !body || !("token" in body)) {
        throw new Error(body && "error" in body ? body.error?.message || "Pairing failed." : "Pairing failed.");
      }
      await pair({ baseUrl: url.toString(), token: body.token });
      router.replace("/inbox");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
      scanned.current = false;
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    if (params.base && params.secret) void claim(params.base, params.secret);
  }, [params.base, params.secret]);

  const scan = ({ data }: { data: string }) => {
    try {
      const url = new URL(data);
      if (url.protocol !== "patchwork:" || url.hostname !== "pair") throw new Error();
      const base = url.searchParams.get("base");
      const secret = url.searchParams.get("secret");
      if (!base || !secret) throw new Error();
      void claim(base, secret);
    } catch {
      setError("That is not a Patchwork pairing code.");
    }
  };

  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: theme.bg }]} edges={["top", "bottom"]}>
      <PageHeader title="Pair this device" back />
      <View style={styles.body}>
        {busy ? (
          <View style={styles.center}>
            <ActivityIndicator size="large" color={theme.accent} />
            <Text style={{ color: theme.muted }}>Joining your workspace…</Text>
          </View>
        ) : permission?.granted ? (
          <>
            <View style={[styles.cameraFrame, { borderColor: theme.line }]}>
              <CameraView
                style={styles.camera}
                facing="back"
                barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
                onBarcodeScanned={scan}
              />
              <View pointerEvents="none" style={[styles.target, { borderColor: theme.onAccent }]} />
            </View>
            <Text style={[styles.help, { color: theme.muted }]}>On Desktop, open Members and choose Pair phone or tablet. Point this camera at the code.</Text>
          </>
        ) : (
          <View style={styles.center}>
            <Text style={[styles.permissionTitle, { color: theme.text }]}>Camera access is needed once</Text>
            <Text style={[styles.help, { color: theme.muted }]}>The code contains a short-lived pairing secret, never your existing Desktop key.</Text>
            <Button label="Allow camera" onPress={() => void requestPermission()} />
          </View>
        )}
        <ErrorNotice message={error} />
      </View>
    </SafeAreaView>
  );
}

function deviceLabel() {
  return `Patchwork ${process.env.EXPO_OS === "ios" ? "iPhone or iPad" : "Android"}`;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  body: { flex: 1, padding: 20, gap: 16 },
  center: { flex: 1, justifyContent: "center", alignItems: "center", gap: 14, padding: 24 },
  cameraFrame: { flex: 1, maxHeight: 620, borderWidth: StyleSheet.hairlineWidth, borderRadius: 18, overflow: "hidden" },
  camera: { flex: 1 },
  target: { position: "absolute", width: 230, height: 230, borderRadius: 22, borderWidth: 3, alignSelf: "center", top: "30%" },
  help: { fontSize: 15, lineHeight: 22, textAlign: "center" },
  permissionTitle: { fontSize: 20, fontWeight: "700", textAlign: "center" },
});
