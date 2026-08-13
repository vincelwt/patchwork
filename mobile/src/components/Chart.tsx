// A chart posted by an agent is a Flint spec, not a picture, so the phone draws
// it: same spec, same library, native SVG instead of a canvas or a web view.

import { useEffect, useMemo, useRef, useState } from "react";
import { StyleSheet, Text, useColorScheme, View } from "react-native";
import SvgChart, { SVGRenderer } from "@wuba/react-native-echarts/svgChart";
import {
  BarChart,
  BoxplotChart,
  CustomChart,
  HeatmapChart,
  LineChart,
  PieChart,
  ScatterChart,
} from "echarts/charts";
import {
  GraphicComponent,
  GridComponent,
  LegendComponent,
  TitleComponent,
  TooltipComponent,
  VisualMapComponent,
} from "echarts/components";
import * as echarts from "echarts/core";
import type { EChartsType } from "echarts";
import type { ChartAssemblyInput } from "flint-chart";
import { assembleECharts } from "flint-chart/echarts";

import { normalizedChartSpec } from "@client/evidence";
import { useTheme } from "@/lib/theme";

// Only what the chart types in the agent guidance need: bar, line, area,
// scatter, pie, histogram, heatmap and box plot. `tslib` is pinned through the
// npm override because older copies lose their helpers in current Metro.
echarts.use([
  SVGRenderer,
  BarChart,
  BoxplotChart,
  CustomChart,
  HeatmapChart,
  LineChart,
  PieChart,
  ScatterChart,
  GraphicComponent,
  GridComponent,
  LegendComponent,
  TitleComponent,
  TooltipComponent,
  VisualMapComponent,
]);

export function ChartCard({ spec, caption }: { spec: unknown; caption?: string }) {
  const theme = useTheme();
  const dark = useColorScheme() === "dark";
  const chart = useRef(null);
  const [width, setWidth] = useState(0);
  const [failed, setFailed] = useState(false);
  // A reaction or an edit hands us a fresh copy of the same message, and
  // redrawing because an emoji arrived would be a visible flicker. Only the
  // contents decide whether it is a different chart.
  const identity = useMemo(() => JSON.stringify(spec), [spec]);
  const height = Math.round(Math.max(200, Math.min(320, width * 0.72)));

  useEffect(() => {
    if (!width || !chart.current) return;
    setFailed(false);
    let instance: EChartsType | undefined;
    try {
      const option = assembleECharts(
        normalizedChartSpec(JSON.parse(identity)) as ChartAssemblyInput,
      );
      instance = echarts.init(chart.current, dark ? "dark" : undefined, {
        renderer: "svg",
        width,
        height,
      });
      // No title inside the plot: the message above the chart is its title.
      // The transcript sits behind it, so no background either.
      instance.setOption({ ...option, title: undefined, backgroundColor: "transparent" });
    } catch {
      // A spec we cannot draw is one quiet card, never a broken transcript.
      setFailed(true);
    }
    return () => instance?.dispose();
  }, [identity, dark, width, height]);

  return (
    <View
      accessible
      accessibilityRole="image"
      accessibilityLabel={caption ? `Chart. ${caption}` : "Chart"}
      onLayout={({ nativeEvent }) => setWidth(Math.round(nativeEvent.layout.width))}
      style={[styles.card, { backgroundColor: theme.surface, borderColor: theme.line }]}
    >
      {/* Kept mounted while it is failing: the next spec, width or theme is
          what gets a second try, and it needs somewhere to draw. */}
      <View style={{ height: failed ? 0 : height }}>
        <SvgChart ref={chart} />
      </View>
      {failed ? <Text style={{ color: theme.muted }}>That chart could not be drawn.</Text> : null}
      {caption ? <Text style={[styles.caption, { color: theme.muted }]}>{caption}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 11, padding: 10, gap: 6, marginTop: 7, overflow: "hidden" },
  caption: { fontSize: 13, lineHeight: 18 },
});
