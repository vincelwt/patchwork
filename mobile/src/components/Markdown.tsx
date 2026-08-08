import { Fragment, memo, type ReactNode } from "react";
import { Linking, ScrollView, StyleSheet, Text, View } from "react-native";

import { useTheme } from "@/lib/theme";

export const Markdown = memo(function Markdown({ body, compact }: { body: string; compact?: boolean }) {
  const theme = useTheme();
  const size = compact ? 14 : 16;
  const blocks = body.split(/```/);

  return (
    <View style={styles.body}>
      {blocks.map((block, index) => index % 2 ? (
        <ScrollView horizontal key={index} style={[styles.code, { backgroundColor: theme.code }]}>
          <Text selectable style={{ color: theme.text, fontFamily: "monospace", fontSize: size - 1 }}>{block.replace(/^\w*\n/, "").trimEnd()}</Text>
        </ScrollView>
      ) : (
        <Fragment key={index}>
          {block.split("\n").map((line, lineIndex) => {
            if (!line) return <View key={lineIndex} style={{ height: compact ? 4 : 7 }} />;
            const heading = /^(#{1,3})\s+(.*)$/.exec(line);
            const bullet = /^[-*]\s+(.*)$/.exec(line);
            const ordered = /^(\d+)\.\s+(.*)$/.exec(line);
            const quote = /^>\s?(.*)$/.exec(line);
            if (heading) return <Text selectable key={lineIndex} style={[styles.heading, { color: theme.text, fontSize: size + 8 - heading[1].length * 2 }]}>{inline(heading[2], theme)}</Text>;
            if (bullet) return <Text selectable key={lineIndex} style={[styles.line, { color: theme.text, fontSize: size }]}>  •  {inline(bullet[1], theme)}</Text>;
            if (ordered) return <Text selectable key={lineIndex} style={[styles.line, { color: theme.text, fontSize: size }]}>  {ordered[1]}.  {inline(ordered[2], theme)}</Text>;
            if (quote) return <Text selectable key={lineIndex} style={[styles.quote, { color: theme.muted, borderLeftColor: theme.accent, fontSize: size }]}>{inline(quote[1], theme)}</Text>;
            return <Text selectable key={lineIndex} style={[styles.line, { color: theme.text, fontSize: size }]}>{inline(line, theme)}</Text>;
          })}
        </Fragment>
      ))}
    </View>
  );
});

function inline(text: string, theme: ReturnType<typeof useTheme>): ReactNode[] {
  const parts = text.split(/(\[[^\]]+\]\(https?:\/\/[^)]+\)|`[^`]+`|\*\*[^*]+\*\*)/g);
  return parts.map((part, index) => {
    const link = /^\[([^\]]+)\]\((https?:\/\/[^)]+)\)$/.exec(part);
    if (link) return <Text accessibilityRole="link" key={index} onPress={() => void Linking.openURL(link[2])} style={{ color: theme.accent }}>{link[1]}</Text>;
    if (part.startsWith("`") && part.endsWith("`")) return <Text key={index} style={{ backgroundColor: theme.code, fontFamily: "monospace" }}>{part.slice(1, -1)}</Text>;
    if (part.startsWith("**") && part.endsWith("**")) return <Text key={index} style={{ fontWeight: "700" }}>{part.slice(2, -2)}</Text>;
    return part;
  });
}

const styles = StyleSheet.create({
  body: { gap: 2 },
  line: { lineHeight: 22 },
  heading: { fontWeight: "700", lineHeight: 30, marginTop: 6 },
  quote: { borderLeftWidth: 3, lineHeight: 22, paddingLeft: 10 },
  code: { borderRadius: 8, marginVertical: 5, padding: 10 },
});
