import { useState, type ReactNode } from "react";
import { SymbolView, type SymbolViewProps } from "expo-symbols";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
  type TextInputProps,
  type ViewStyle,
} from "react-native";
import { useRouter } from "expo-router";
import { SafeAreaView } from "react-native-safe-area-context";

import type { Member, Presence } from "@client/types";
import type { ConnectionState } from "@/lib/store";
import { useTheme, type Palette } from "@/lib/theme";

export function Screen({ children, style }: { children: ReactNode; style?: ViewStyle }) {
  const theme = useTheme();
  return <View style={[styles.screen, { backgroundColor: theme.bg }, style]}>{children}</View>;
}

export function Icon({
  name,
  color,
  size = 22,
}: {
  name: SymbolViewProps["name"];
  color: string;
  size?: number;
}) {
  return <SymbolView name={name} size={size} tintColor={color} style={{ width: size, height: size }} />;
}

export function ScrollScreen({ children }: { children: ReactNode }) {
  const theme = useTheme();
  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: theme.bg }}
      contentContainerStyle={styles.scroll}
      keyboardShouldPersistTaps="handled"
    >
      {children}
    </ScrollView>
  );
}

export function PageHeader({
  title,
  subtitle,
  back,
  action,
}: {
  title: string;
  subtitle?: string;
  back?: boolean;
  action?: ReactNode;
}) {
  const theme = useTheme();
  const router = useRouter();
  return (
    <View style={[styles.header, back && styles.headerCompact, { borderBottomColor: theme.line, backgroundColor: theme.raised }]}>
      {back ? (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Go back"
          hitSlop={8}
          onPress={() => router.back()}
          style={({ pressed }) => [styles.back, pressed && styles.pressed]}
        >
          <Icon name={{ ios: "chevron.left", android: "arrow_back", web: "arrow_back" }} color={theme.accent} size={22} />
        </Pressable>
      ) : null}
      <View style={styles.grow}>
        <Text accessibilityRole="header" numberOfLines={1} style={[styles.title, back && styles.titleCompact, { color: theme.text }]}>
          {title}
        </Text>
        {subtitle ? (
          <Text numberOfLines={1} style={[styles.subtitle, { color: theme.muted }]}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      {action}
    </View>
  );
}

export function Button({
  label,
  onPress,
  disabled,
  tone = "primary",
  busy,
  compact,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
  tone?: "primary" | "secondary" | "danger" | "quiet";
  busy?: boolean;
  compact?: boolean;
}) {
  const theme = useTheme();
  const colours =
    tone === "primary"
      ? { background: theme.accent, text: theme.onAccent, border: theme.accent }
      : tone === "danger"
        ? { background: theme.dangerSoft, text: theme.danger, border: theme.dangerSoft }
        : tone === "quiet"
          ? { background: "transparent", text: theme.accent, border: "transparent" }
          : { background: theme.surface, text: theme.text, border: theme.line };
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled || !!busy }}
      disabled={disabled || busy}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        compact && styles.buttonCompact,
        { backgroundColor: colours.background, borderColor: colours.border },
        pressed && styles.pressed,
        (disabled || busy) && styles.disabled,
      ]}
    >
      {busy ? <ActivityIndicator color={colours.text} size="small" /> : null}
      <Text style={[styles.buttonText, { color: colours.text }]}>{label}</Text>
    </Pressable>
  );
}

export function TextField({
  label,
  help,
  error,
  multiline,
  ...props
}: TextInputProps & { label?: string; help?: string; error?: string }) {
  const theme = useTheme();
  return (
    <View style={styles.fieldWrap}>
      {label ? <Text style={[styles.label, { color: theme.text }]}>{label}</Text> : null}
      <TextInput
        {...props}
        multiline={multiline}
        placeholderTextColor={theme.faint}
        selectionColor={theme.accent}
        style={[
          styles.field,
          multiline && styles.fieldMultiline,
          { color: theme.text, backgroundColor: theme.input, borderColor: error ? theme.danger : theme.line },
          props.style,
        ]}
      />
      {error ? <Text style={[styles.help, { color: theme.danger }]}>{error}</Text> : null}
      {!error && help ? <Text style={[styles.help, { color: theme.muted }]}>{help}</Text> : null}
    </View>
  );
}

export interface Choice {
  value: string;
  label: string;
  description?: string;
}

export function ChoiceField({
  label,
  value,
  options,
  onChange,
  placeholder = "Choose",
  disabled,
}: {
  label?: string;
  value?: string;
  options: Choice[];
  onChange: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
}) {
  const theme = useTheme();
  const [open, setOpen] = useState(false);
  const selected = options.find((option) => option.value === value);
  return (
    <View style={styles.fieldWrap}>
      {label ? <Text style={[styles.label, { color: theme.text }]}>{label}</Text> : null}
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={label}
        disabled={disabled}
        onPress={() => setOpen(true)}
        style={({ pressed }) => [
          styles.choice,
          { backgroundColor: theme.input, borderColor: theme.line },
          pressed && styles.pressed,
          disabled && styles.disabled,
        ]}
      >
        <Text numberOfLines={1} style={[styles.choiceText, { color: selected ? theme.text : theme.faint }]}>
          {selected?.label ?? placeholder}
        </Text>
        <Icon name={{ ios: "chevron.down", android: "arrow_drop_down", web: "arrow_drop_down" }} color={theme.faint} size={16} />
      </Pressable>
      <Sheet visible={open} title={label ?? "Choose"} onClose={() => setOpen(false)}>
        <ScrollView style={styles.choiceList}>
          {options.map((option) => (
            <Pressable
              key={option.value}
              onPress={() => {
                onChange(option.value);
                setOpen(false);
              }}
              style={({ pressed }) => [
                styles.choiceRow,
                { borderBottomColor: theme.line },
                option.value === value && { backgroundColor: theme.accentSoft },
                pressed && styles.pressed,
              ]}
            >
              <View style={styles.grow}>
                <Text style={[styles.rowTitle, { color: theme.text }]}>{option.label}</Text>
                {option.description ? (
                  <Text style={[styles.rowSubtitle, { color: theme.muted }]}>{option.description}</Text>
                ) : null}
              </View>
              {option.value === value ? (
                <Icon name={{ ios: "checkmark", android: "check", web: "check" }} color={theme.accent} size={18} />
              ) : null}
            </Pressable>
          ))}
        </ScrollView>
      </Sheet>
    </View>
  );
}

export function ToggleRow({
  label,
  detail,
  value,
  onChange,
  disabled,
}: {
  label: string;
  detail?: string;
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  const theme = useTheme();
  return (
    <View style={styles.toggleRow}>
      <View style={styles.grow}>
        <Text style={[styles.rowTitle, { color: theme.text }]}>{label}</Text>
        {detail ? <Text style={[styles.rowSubtitle, { color: theme.muted }]}>{detail}</Text> : null}
      </View>
      <Switch value={value} onValueChange={onChange} disabled={disabled} trackColor={{ true: theme.accent }} />
    </View>
  );
}

export function Sheet({
  visible,
  title,
  onClose,
  children,
}: {
  visible: boolean;
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  const theme = useTheme();
  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle={Platform.OS === "ios" ? "pageSheet" : "fullScreen"}
      allowSwipeDismissal
      onRequestClose={onClose}
    >
      <SafeAreaView style={[styles.modalSafe, { backgroundColor: theme.bg }]} edges={["top", "bottom"]}>
        <KeyboardAvoidingView
          behavior={Platform.OS === "ios" ? "padding" : undefined}
          style={styles.modal}
        >
          <View style={[styles.sheet, { backgroundColor: theme.bg }]}>
            <View style={[styles.sheetHead, { backgroundColor: theme.raised, borderBottomColor: theme.line }]}>
              <Text accessibilityRole="header" style={[styles.sheetTitle, { color: theme.text }]}>
                {title}
              </Text>
              <Button label="Done" tone="quiet" compact onPress={onClose} />
            </View>
            {children}
          </View>
        </KeyboardAvoidingView>
      </SafeAreaView>
    </Modal>
  );
}

export function Card({ children, style }: { children: ReactNode; style?: ViewStyle }) {
  const theme = useTheme();
  return (
    <View style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }, style]}>
      {children}
    </View>
  );
}

export function Badge({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: "neutral" | "accent" | "positive" | "caution" | "danger";
}) {
  const theme = useTheme();
  const colour =
    tone === "accent"
      ? theme.accent
      : tone === "positive"
        ? theme.positive
        : tone === "caution"
          ? theme.caution
          : tone === "danger"
            ? theme.danger
            : theme.muted;
  const background =
    tone === "accent"
      ? theme.accentSoft
      : tone === "positive"
        ? theme.positiveSoft
        : tone === "caution"
          ? theme.cautionSoft
          : tone === "danger"
            ? theme.dangerSoft
            : theme.raised;
  return (
    <View style={[styles.badge, { backgroundColor: background }]}>
      <Text style={[styles.badgeText, { color: colour }]}>{children}</Text>
    </View>
  );
}

export function Avatar({ member, size = 34 }: { member?: Member; size?: number }) {
  const theme = useTheme();
  const initials = member?.display_name
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase() || "?";
  return (
    <View
      style={[
        styles.avatar,
        { width: size, height: size, borderRadius: size / 3, backgroundColor: member?.kind === "agent" ? theme.accentSoft : theme.surface },
      ]}
    >
      <Text style={[styles.avatarText, { color: member?.kind === "agent" ? theme.accent : theme.text, fontSize: size * 0.36 }]}>
        {initials}
      </Text>
      {member ? <PresenceDot presence={member.presence} /> : null}
    </View>
  );
}

function PresenceDot({ presence }: { presence: Presence }) {
  const theme = useTheme();
  const colour =
    presence === "online" || presence === "working"
      ? theme.positive
      : presence === "waiting"
        ? theme.caution
        : theme.faint;
  return <View style={[styles.presence, { backgroundColor: colour, borderColor: theme.bg }]} />;
}

export function Empty({ title, detail }: { title: string; detail?: string }) {
  const theme = useTheme();
  return (
    <View style={styles.empty}>
      <Text style={[styles.emptyTitle, { color: theme.text }]}>{title}</Text>
      {detail ? <Text style={[styles.emptyDetail, { color: theme.muted }]}>{detail}</Text> : null}
    </View>
  );
}

export function Loading({ label = "Loading" }: { label?: string }) {
  const theme = useTheme();
  return (
    <View style={styles.loading}>
      <ActivityIndicator color={theme.accent} />
      <Text style={{ color: theme.muted }}>{label}</Text>
    </View>
  );
}

export function ErrorNotice({ message }: { message?: string }) {
  const theme = useTheme();
  return message ? (
    <View style={[styles.notice, { backgroundColor: theme.dangerSoft }]}>
      <Text style={{ color: theme.danger }}>{message}</Text>
    </View>
  ) : null;
}

export function ConnectionBar({ connection, error }: { connection: ConnectionState; error?: string }) {
  const theme = useTheme();
  if (connection === "live") return null;
  const message =
    connection === "offline"
      ? "Offline. Showing saved workspace data."
      : connection === "connecting"
        ? "Reconnecting…"
        : error
          ? "Could not reach the workspace. Reconnecting…"
          : "Could not reach the workspace.";
  return (
    <View accessibilityLiveRegion="polite" style={[styles.connection, { backgroundColor: connection === "error" ? theme.dangerSoft : theme.cautionSoft }]}>
      {connection === "connecting" ? <ActivityIndicator size="small" color={theme.caution} /> : null}
      <Text numberOfLines={2} style={{ flexShrink: 1, color: connection === "error" ? theme.danger : theme.caution }}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  scroll: { padding: 16, gap: 14, paddingBottom: 36 },
  grow: { flex: 1 },
  header: {
    minHeight: 72,
    paddingHorizontal: 18,
    paddingVertical: 11,
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
  },
  headerCompact: { minHeight: 58, paddingVertical: 8, paddingLeft: 10 },
  back: { width: 38, minHeight: 42, alignItems: "center", justifyContent: "center" },
  title: { fontSize: 28, fontWeight: "700", letterSpacing: -0.7 },
  titleCompact: { fontSize: 20, letterSpacing: -0.25 },
  subtitle: { fontSize: 13, marginTop: 1 },
  button: {
    minHeight: 44,
    paddingHorizontal: 16,
    borderRadius: 11,
    borderWidth: StyleSheet.hairlineWidth,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
  },
  buttonCompact: { minHeight: 36, paddingHorizontal: 10 },
  buttonText: { fontSize: 15, fontWeight: "600" },
  pressed: { opacity: 0.6 },
  disabled: { opacity: 0.42 },
  fieldWrap: { gap: 6 },
  label: { fontSize: 13, fontWeight: "600" },
  field: {
    minHeight: 46,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 16,
  },
  fieldMultiline: { minHeight: 96, textAlignVertical: "top" },
  help: { fontSize: 12, lineHeight: 17 },
  choice: {
    minHeight: 46,
    flexDirection: "row",
    alignItems: "center",
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 10,
    paddingHorizontal: 12,
    gap: 8,
  },
  choiceText: { flex: 1, fontSize: 16 },
  choiceList: { maxHeight: 500 },
  choiceRow: {
    minHeight: 52,
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  rowTitle: { fontSize: 15, fontWeight: "600" },
  rowSubtitle: { fontSize: 13, lineHeight: 18, marginTop: 2 },
  toggleRow: { flexDirection: "row", alignItems: "center", gap: 12, minHeight: 54 },
  modalSafe: { flex: 1 },
  modal: { flex: 1 },
  sheet: { flex: 1 },
  sheetHead: {
    minHeight: 54,
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  sheetTitle: { flex: 1, fontSize: 17, fontWeight: "700" },
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 13, overflow: "hidden" },
  badge: { alignSelf: "flex-start", borderRadius: 999, paddingHorizontal: 8, paddingVertical: 4 },
  badgeText: { fontSize: 11, fontWeight: "700" },
  avatar: { alignItems: "center", justifyContent: "center" },
  avatarText: { fontWeight: "700" },
  presence: { position: "absolute", right: -2, bottom: -2, width: 10, height: 10, borderRadius: 5, borderWidth: 2 },
  empty: { alignItems: "center", justifyContent: "center", padding: 32, gap: 6 },
  emptyTitle: { fontSize: 17, fontWeight: "600", textAlign: "center" },
  emptyDetail: { fontSize: 14, lineHeight: 20, textAlign: "center" },
  loading: { flex: 1, alignItems: "center", justifyContent: "center", gap: 10, padding: 30 },
  notice: { borderRadius: 10, padding: 12 },
  connection: { minHeight: 34, flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 8, paddingHorizontal: 12, paddingVertical: 7 },
});
