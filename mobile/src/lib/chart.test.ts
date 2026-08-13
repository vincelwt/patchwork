// The phone registers ECharts piece by piece, so this keeps its small native
// renderer in step with every chart type the agent guidance tells agents to
// send.

import assert from "node:assert/strict";
import test from "node:test";
import type { ChartAssemblyInput } from "flint-chart";
import { assembleECharts } from "flint-chart/echarts";
import { normalizedChartSpec } from "../../../client/evidence.ts";

/// Series and components registered in `src/components/Chart.tsx`. Keep in step.
const SERIES = ["bar", "line", "scatter", "pie", "heatmap", "boxplot", "custom"];
const COMPONENTS = ["graphic", "grid", "legend", "title", "tooltip", "visualMap"];
/// Not components: axes come with the grid, and these are read by the renderer.
const IGNORED = ["series", "xAxis", "yAxis", "backgroundColor", "animation", "color", "textStyle"];

const rows = [
  { day: "2026-08-01", region: "North", amount: 12, score: 3 },
  { day: "2026-08-02", region: "South", amount: 30, score: 8 },
  { day: "2026-08-03", region: "North", amount: 21, score: 5 },
  { day: "2026-08-04", region: "South", amount: 44, score: 9 },
];

const charts: [string, Record<string, { field: string }>][] = [
  ["Bar Chart", { x: { field: "region" }, y: { field: "amount" } }],
  ["Line Chart", { x: { field: "day" }, y: { field: "amount" } }],
  ["Area Chart", { x: { field: "day" }, y: { field: "amount" } }],
  ["Scatter Plot", { x: { field: "amount" }, y: { field: "score" } }],
  ["Pie Chart", { color: { field: "region" }, size: { field: "amount" } }],
  ["Histogram", { x: { field: "amount" } }],
  ["Heatmap", { x: { field: "day" }, y: { field: "region" }, color: { field: "amount" } }],
  ["Box Plot", { x: { field: "region" }, y: { field: "amount" } }],
];

for (const [chartType, encodings] of charts) {
  test(`${chartType} only needs what the phone registers`, () => {
    const option = assembleECharts(normalizedChartSpec({
      data: { values: rows },
      semantic_types: { day: "Date", region: "Category", amount: "Count", score: "Rank" },
      chart_spec: { chartType, encodings },
    }) as ChartAssemblyInput) as Record<string, unknown> & { series?: { type?: string }[] };

    const series = [option.series ?? []].flat();
    assert.ok(series.length > 0, `${chartType} drew no series`);
    for (const one of series) {
      assert.ok(SERIES.includes(one.type ?? ""), `${chartType} needs series "${one.type}"`);
    }
    for (const key of Object.keys(option)) {
      // Flint's own layout hints start with an underscore.
      if (key.startsWith("_") || IGNORED.includes(key)) continue;
      assert.ok(COMPONENTS.includes(key), `${chartType} needs component "${key}"`);
    }
  });
}
