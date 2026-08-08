import { Redirect, Slot, usePathname, useRouter } from "expo-router";
import { Pressable, StyleSheet, Text, useWindowDimensions, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

import { ConnectionBar } from "@/components/ui";
import { Mark } from "@/app/index";
import { usePairedSession } from "@/lib/session";
import { useWorkspace } from "@/lib/store";
import { useTheme } from "@/lib/theme";

const primary = [
  { href: "/(app)/inbox", label: "Inbox" },
  { href: "/(app)/channels", label: "Chat" },
  { href: "/(app)/tasks", label: "Tasks" },
  { href: "/(app)/agents", label: "Agents" },
  { href: "/(app)/more", label: "More" },
] as const;

const tablet = [
  ...primary.slice(0, 4),
  { href: "/(app)/search", label: "Search" },
  { href: "/(app)/automations", label: "Automations" },
  { href: "/(app)/members", label: "Members" },
  { href: "/(app)/settings", label: "Settings" },
] as const;

export default function AppLayout() {
  const { session } = usePairedSession();
  const workspace = useWorkspace();
  const theme = useTheme();
  const pathname = usePathname();
  const router = useRouter();
  const { width } = useWindowDimensions();
  const wide = width >= 760;

  if (session === null) return <Redirect href="/" />;

  const nav = (item: (typeof tablet)[number], compact = false) => {
    const path = item.href.replace("/(app)", "");
    const active = pathname === path || (path !== "/inbox" && pathname.startsWith(`${path}/`));
    const count = item.label === "Inbox" ? unread(workspace) : 0;
    return (
      <Pressable
        key={item.href}
        accessibilityRole="tab"
        accessibilityLabel={count ? `${item.label}, ${count} unread` : item.label}
        accessibilityState={{ selected: active }}
        onPress={() => router.navigate(item.href)}
        style={({ pressed }) => [
          compact ? styles.bottomItem : styles.sideItem,
          active && { backgroundColor: theme.accentSoft },
          pressed && styles.pressed,
        ]}
      >
        <Text
          numberOfLines={1}
          style={[compact ? styles.bottomLabel : styles.sideLabel, { color: active ? theme.accent : theme.muted }]}
        >
          {item.label}
        </Text>
        {count ? (
          <View style={[styles.unread, compact && styles.unreadFloat, { backgroundColor: theme.danger }]}>
            <Text style={styles.unreadText}>{Math.min(99, count)}</Text>
          </View>
        ) : null}
      </Pressable>
    );
  };

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: wide ? theme.sidebar : theme.bg }]} edges={["top", "bottom"]}>
      <View style={styles.row}>
        {wide ? (
          <View style={[styles.sidebar, { backgroundColor: theme.sidebar, borderRightColor: theme.line }]}>
            <View style={styles.brand}>
              <Mark size={34} />
              <View style={styles.grow}>
                <Text style={[styles.workspace, { color: theme.text }]} numberOfLines={1}>
                  {workspace.bootstrap?.workspace.name ?? "Patchwork"}
                </Text>
                <Text style={[styles.connectionText, { color: workspace.connection === "live" ? theme.positive : theme.caution }]}>
                  {workspace.connection === "live" ? "Live" : workspace.connection}
                </Text>
              </View>
            </View>
            <View style={styles.sideNav}>{tablet.map((item) => nav(item))}</View>
            <Text style={[styles.signedIn, { color: theme.faint }]} numberOfLines={1}>
              {workspace.bootstrap?.me.display_name}
            </Text>
          </View>
        ) : null}
        <View style={[styles.main, { backgroundColor: theme.bg }]}>
          <ConnectionBar connection={workspace.connection} error={workspace.error} />
          <Slot />
          {!wide ? <View style={[styles.bottom, { backgroundColor: theme.raised, borderTopColor: theme.line }]}>{primary.map((item) => nav(item, true))}</View> : null}
        </View>
      </View>
    </SafeAreaView>
  );
}

function unread(workspace: ReturnType<typeof useWorkspace>) {
  return workspace.bootstrap?.inbox.filter((item) => !item.read_at).length ?? 0;
}

const styles = StyleSheet.create({
  safe: { flex: 1 },
  row: { flex: 1, flexDirection: "row" },
  grow: { flex: 1 },
  main: { flex: 1, minWidth: 0 },
  sidebar: { width: 248, borderRightWidth: StyleSheet.hairlineWidth, padding: 12 },
  brand: { minHeight: 58, flexDirection: "row", alignItems: "center", gap: 10, paddingHorizontal: 8 },
  workspace: { fontSize: 17, fontWeight: "700" },
  connectionText: { fontSize: 11, textTransform: "capitalize", marginTop: 1 },
  sideNav: { flex: 1, paddingTop: 12, gap: 3 },
  sideItem: { minHeight: 46, borderRadius: 10, flexDirection: "row", alignItems: "center", paddingHorizontal: 12, gap: 8 },
  sideLabel: { flex: 1, fontSize: 15, fontWeight: "600" },
  signedIn: { padding: 10, fontSize: 12 },
  bottom: { flexDirection: "row", paddingHorizontal: 4, paddingVertical: 6, borderTopWidth: StyleSheet.hairlineWidth },
  bottomItem: { flex: 1, minHeight: 46, marginHorizontal: 2, borderRadius: 12, alignItems: "center", justifyContent: "center" },
  bottomLabel: { fontSize: 11, fontWeight: "600" },
  unread: { minWidth: 18, height: 18, borderRadius: 9, paddingHorizontal: 4, alignItems: "center", justifyContent: "center" },
  unreadFloat: { position: "absolute", top: 3, left: "54%" },
  unreadText: { color: "white", fontSize: 10, fontWeight: "800" },
  pressed: { opacity: 0.58 },
});
