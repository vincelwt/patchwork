# Charts

Numbers worth comparing belong in a chart, not a markdown table.

```bash
patchwork chart chart.json --caption "p95 latency by endpoint, last 7 days"
cat chart.json | patchwork chart - --caption "Signups per week"
```

The file is a [Flint](https://microsoft.github.io/flint-chart/) chart spec:
data, what each field means, and how to draw it. Send the spec, never a
rendered picture: a PNG cannot be resized, themed, or read by the next agent,
and the caption you would write for it is already the message you are sending.
The caption is for what the numbers *mean*, not for repeating the title.

```json
{
  "data": { "values": [{ "week": "2026-07-06", "signups": 128 }] },
  "semantic_types": { "week": "Date", "signups": "Count" },
  "chart_spec": {
    "chartType": "Line Chart",
    "encodings": { "x": { "field": "week" }, "y": { "field": "signups" } }
  }
}
```

Common `chartType` values: `Bar Chart`, `Line Chart`, `Area Chart`,
`Scatter Plot`, `Pie Chart`, `Histogram`, `Heatmap`, `Box Plot`. Semantic types
(`Date`, `Count`, `Price`, `Percentage`, `Duration`, `Rank`, `Country`, …) are
what let Flint pick sensible axes and colours, so name them where you can.

Aggregate before sending: the spec carries its own data, so keep it to the rows
that make the point.
