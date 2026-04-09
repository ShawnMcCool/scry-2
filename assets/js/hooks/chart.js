// ECharts hook for rank progression charts.
//
// Each chart element must provide:
//   data-chart-type  — "climb" | "momentum"
//   data-series      — JSON-encoded series data from the server
//
// The hook initialises ECharts on mount and updates data in-place on
// subsequent LiveView patches, avoiding full re-initialisation (no flicker).

import * as echarts from "../../vendor/echarts.min"

const RANK_AXIS_TICKS = [
  [0, "Bronze"],
  [24, "Silver"],
  [48, "Gold"],
  [72, "Platinum"],
  [96, "Diamond"],
  [120, "Mythic"],
]

function climbOption(series) {
  return {
    backgroundColor: "transparent",
    grid: {left: 80, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        const [ts, score] = params[0].data
        const date = new Date(ts).toLocaleString()
        const label = rankLabel(score)
        return `${date}<br/><b>${label}</b>`
      },
    },
    xAxis: {
      type: "time",
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
    yAxis: {
      type: "value",
      min: 0,
      max: 120,
      interval: 24,
      axisLabel: {
        color: "#9ca3af",
        fontSize: 11,
        formatter(value) {
          const tick = RANK_AXIS_TICKS.find(([v]) => v === value)
          return tick ? tick[1] : ""
        },
      },
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {lineStyle: {color: "#1f2937"}},
    },
    series: [
      {
        type: "line",
        step: "end",
        data: series,
        smooth: false,
        symbol: "circle",
        symbolSize: 4,
        lineStyle: {color: "#6366f1", width: 2},
        itemStyle: {color: "#6366f1"},
        areaStyle: {color: "rgba(99,102,241,0.08)"},
      },
    ],
  }
}

function momentumOption(winsData, lossesData) {
  return {
    backgroundColor: "transparent",
    grid: {left: 48, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        const date = new Date(params[0].data[0]).toLocaleString()
        const wins = params.find(p => p.seriesName === "Wins")?.data[1] ?? 0
        const losses = params.find(p => p.seriesName === "Losses")?.data[1] ?? 0
        return `${date}<br/><b>${wins}W – ${losses}L</b>`
      },
    },
    xAxis: {
      type: "time",
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
    yAxis: {
      type: "value",
      minInterval: 1,
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {lineStyle: {color: "#1f2937"}},
    },
    series: [
      {
        name: "Wins",
        type: "line",
        data: winsData,
        smooth: false,
        symbol: "none",
        lineStyle: {color: "#22c55e", width: 2},
        itemStyle: {color: "#22c55e"},
        areaStyle: {color: "rgba(34,197,94,0.12)"},
      },
      {
        name: "Losses",
        type: "line",
        data: lossesData,
        smooth: false,
        symbol: "none",
        lineStyle: {color: "#f97316", width: 2},
        itemStyle: {color: "#f97316"},
        areaStyle: {color: "rgba(249,115,22,0.08)"},
      },
    ],
  }
}

function rankLabel(score) {
  if (score >= 120) return "Mythic"
  const classIndex = Math.floor(score / 24)
  const withinClass = score % 24
  const level = 4 - Math.floor(withinClass / 6)
  const classes = ["Bronze", "Silver", "Gold", "Platinum", "Diamond"]
  return `${classes[classIndex] || "Bronze"} ${level}`
}

function buildOption(el) {
  const type = el.dataset.chartType
  const parsed = JSON.parse(el.dataset.series || "[]")

  if (type === "climb") {
    return climbOption(parsed)
  } else {
    const [wins, losses] = parsed
    return momentumOption(wins || [], losses || [])
  }
}

export const Chart = {
  mounted() {
    this.chart = echarts.init(this.el, null, {renderer: "canvas"})
    this.chart.setOption(buildOption(this.el))
    this.resizeObserver = new ResizeObserver(() => this.chart.resize())
    this.resizeObserver.observe(this.el)
  },

  updated() {
    this.chart.setOption(buildOption(this.el), {notMerge: false, lazyUpdate: false})
  },

  destroyed() {
    this.resizeObserver?.disconnect()
    this.chart?.dispose()
  },
}
