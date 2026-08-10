import { Redirect, useRouter } from "expo-router";
import { ActivityIndicator, Linking, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

import { Button, Card } from "@/components/ui";
import { usePairedSession } from "@/lib/session";
import { useTheme } from "@/lib/theme";

export default function Index() {
  const { session } = usePairedSession();
  if (session === undefined) return <Loading />;
  if (session) return <Redirect href="/inbox" />;
  return <Welcome />;
}

function Loading() {
  const theme = useTheme();
  return (
    <SafeAreaView style={[styles.fill, styles.center, { backgroundColor: theme.bg }]}>
      <ActivityIndicator color={theme.accent} />
    </SafeAreaView>
  );
}

function Welcome() {
  const theme = useTheme();
  const router = useRouter();
  return (
    <SafeAreaView style={[styles.fill, { backgroundColor: theme.bg }]}>
      <View style={[styles.fill, styles.center, styles.pad]}>
        <Mark />
        <Text accessibilityRole="header" style={[styles.wordmark, { color: theme.text }]}>Patchwork</Text>
        <Text style={[styles.lede, { color: theme.muted }]}>Your workspace, wherever you are.</Text>
        <Card style={styles.card}>
          <Text style={[styles.body, { color: theme.text }]}>Pair this phone or tablet from Patchwork Desktop.</Text>
          <Text style={[styles.detail, { color: theme.muted }]}>Each device receives its own revocable key. Patchwork Relay handles the secure connection automatically.</Text>
          <Button label="Scan pairing code" onPress={() => router.push("/pair")} />
        </Card>
        <View style={styles.links}>
          <Button label="Privacy" tone="quiet" compact onPress={() => void Linking.openURL("https://patchwork.sh/privacy.html")} />
          <Button label="Support" tone="quiet" compact onPress={() => void Linking.openURL("https://patchwork.sh/support.html")} />
        </View>
      </View>
    </SafeAreaView>
  );
}

export function Mark({ size = 76 }: { size?: number }) {
  const cell = (size - 6) / 2;
  return (
    <View style={[styles.mark, { width: size, height: size }]}>
      {["#2f79f7", "#45d6cc", "#ff8a50", "#b56ce8"].map((colour) => (
        <View key={colour} style={{ width: cell, height: cell, borderRadius: cell * 0.3, backgroundColor: colour }} />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  center: { alignItems: "center", justifyContent: "center" },
  pad: { paddingHorizontal: 24 },
  mark: { flexDirection: "row", flexWrap: "wrap", gap: 6, marginBottom: 18 },
  wordmark: { fontSize: 34, fontWeight: "700", letterSpacing: -0.8 },
  lede: { fontSize: 17, marginTop: 6, marginBottom: 24, textAlign: "center" },
  card: { width: "100%", maxWidth: 460, padding: 18, gap: 12 },
  links: { flexDirection: "row", marginTop: 10 },
  body: { fontSize: 17, fontWeight: "600", lineHeight: 23 },
  detail: { fontSize: 14, lineHeight: 20 },
});
