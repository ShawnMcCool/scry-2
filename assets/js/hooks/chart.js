// ECharts hook for rank progression and deck performance charts.
//
// Each chart element must provide:
//   data-chart-type  — "climb" | "momentum" | "winrate" | "curve" | "match_results" | "percentile"
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

function climbOption(climbSeries, resultsSeries, xMin, xMax, yMin, yMax) {
  const hasResults = resultsSeries && resultsSeries.length > 0

  const grids = hasResults
    ? [
        {left: 80, right: 20, top: 16, bottom: 56},
        {left: 80, right: 20, height: 12, bottom: 28},
      ]
    : [{left: 80, right: 20, top: 16, bottom: 40}]

  const xBounds = xMin && xMax ? {min: xMin, max: xMax} : {}

  const xAxes = [
    {
      gridIndex: 0,
      type: "time",
      ...xBounds,
      axisLabel: hasResults ? {show: false} : {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
  ]

  const yAxes = [
    {
      gridIndex: 0,
      type: "value",
      min: yMin,
      max: yMax,
      interval: 24,
      minorTick: {show: true, splitNumber: 4},
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
      minorSplitLine: {show: true, lineStyle: {color: "#111827"}},
    },
  ]

  const series = [
    {
      xAxisIndex: 0,
      yAxisIndex: 0,
      type: "line",
      step: "end",
      data: climbSeries,
      smooth: false,
      symbol: "circle",
      symbolSize: 4,
      lineStyle: {color: "#6366f1", width: 2},
      itemStyle: {color: "#6366f1"},
      areaStyle: {color: "rgba(99,102,241,0.08)"},
    },
  ]

  if (hasResults) {
    xAxes.push({
      gridIndex: 1,
      type: "time",
      ...xBounds,
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    })
    yAxes.push({
      gridIndex: 1,
      type: "value",
      min: 0,
      max: 1,
      axisLabel: {show: false},
      axisTick: {show: false},
      axisLine: {show: false},
      splitLine: {show: false},
    })
    series.push({
      xAxisIndex: 1,
      yAxisIndex: 1,
      type: "bar",
      barMaxWidth: 3,
      barGap: "0%",
      data: resultsSeries.map(([ts, value]) => ({
        value: [ts, 1, value],
        itemStyle: {
          color: value > 0 ? "#22c55e" : "#f97316",
        },
      })),
    })
  }

  return {
    backgroundColor: "transparent",
    axisPointer: hasResults ? {link: [{xAxisIndex: "all"}]} : {},
    grid: grids,
    tooltip: {
      trigger: "axis",
      formatter(params) {
        if (!params.length) return ""
        const ts = params[0].value[0]
        const date = new Date(ts).toLocaleString()
        const climbParam = params.find(p => p.yAxisIndex === 0)
        const resultParam = params.find(p => p.yAxisIndex === 1)
        const rank = climbParam ? rankLabel(climbParam.value[1]) : ""
        const resultValue = resultParam ? resultParam.value[2] : null
        const result = resultValue != null
          ? `<br/>${resultValue > 0 ? "<span style='color:#22c55e'>Win</span>" : "<span style='color:#f97316'>Loss</span>"}`
          : ""
        return `${date}<br/><b>${rank}</b>${result}`
      },
    },
    xAxis: xAxes,
    yAxis: yAxes,
    series,
  }
}

function momentumOption(winsData, lossesData) {
  return {
    backgroundColor: "transparent",
    grid: {left: 80, right: 20, top: 16, bottom: 40},
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

function winrateOption(data) {
  const {weeks = [], bo1 = [], bo3 = []} = data
  const hasBO1 = bo1.some(v => v !== null)
  const hasBO3 = bo3.some(v => v !== null)
  const series = []

  if (hasBO1) {
    series.push({
      name: "BO1",
      type: "line",
      data: weeks.map((w, i) => [w, bo1[i]]),
      connectNulls: false,
      smooth: false,
      symbol: "circle",
      symbolSize: 4,
      lineStyle: {color: "#6366f1", width: 2},
      itemStyle: {color: "#6366f1"},
    })
  }
  if (hasBO3) {
    series.push({
      name: "BO3",
      type: "line",
      data: weeks.map((w, i) => [w, bo3[i]]),
      connectNulls: false,
      smooth: false,
      symbol: "circle",
      symbolSize: 4,
      lineStyle: {color: "#22c55e", width: 2},
      itemStyle: {color: "#22c55e"},
    })
  }

  return {
    backgroundColor: "transparent",
    grid: {left: 52, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        const week = params[0].axisValue
        const lines = params.map(p => `${p.seriesName}: <b>${p.data[1] ?? "—"}%</b>`).join("<br/>")
        return `${week}<br/>${lines}`
      },
    },
    xAxis: {
      type: "category",
      data: weeks,
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
    yAxis: {
      type: "value",
      min: 0,
      max: 100,
      axisLabel: {color: "#9ca3af", fontSize: 11, formatter: v => `${v}%`},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {lineStyle: {color: "#1f2937"}},
    },
    series,
  }
}

function curveOption(data) {
  const labels = data.map(([label]) => label)
  const counts = data.map(([, count]) => count)

  return {
    backgroundColor: "transparent",
    grid: {left: 40, right: 20, top: 16, bottom: 36},
    tooltip: {trigger: "axis"},
    xAxis: {
      type: "category",
      data: labels,
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
        type: "bar",
        data: counts,
        itemStyle: {color: "#6366f1", borderRadius: [3, 3, 0, 0]},
      },
    ],
  }
}

function matchResultsOption(series) {
  return {
    backgroundColor: "transparent",
    grid: {left: 60, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        const [ts, value] = params[0].data
        const date = new Date(ts).toLocaleString()
        const label = value > 0 ? "Win" : "Loss"
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
      min: -1,
      max: 1,
      interval: 1,
      axisLabel: {
        color: "#9ca3af",
        fontSize: 11,
        formatter(value) {
          if (value === 1) return "Win"
          if (value === -1) return "Loss"
          return ""
        },
      },
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {lineStyle: {color: "#1f2937"}},
    },
    series: [
      {
        type: "bar",
        data: series.map(([ts, value]) => ({
          value: [ts, value],
          itemStyle: {color: value > 0 ? "#22c55e" : "#f97316", borderRadius: value > 0 ? [3, 3, 0, 0] : [0, 0, 3, 3]},
        })),
      },
    ],
  }
}

function percentileOption(series) {
  return {
    backgroundColor: "transparent",
    grid: {left: 56, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        const [ts, pct] = params[0].data
        const date = new Date(ts).toLocaleString()
        return `${date}<br/><b>${pct.toFixed(1)}% (lower is better)</b>`
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
      inverse: true,
      axisLabel: {color: "#9ca3af", fontSize: 11, formatter: v => `${v}%`},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {lineStyle: {color: "#1f2937"}},
    },
    series: [
      {
        type: "line",
        data: series,
        smooth: false,
        symbol: "circle",
        symbolSize: 4,
        lineStyle: {color: "#f59e0b", width: 2},
        itemStyle: {color: "#f59e0b"},
        areaStyle: {color: "rgba(245,158,11,0.10)"},
      },
    ],
  }
}

function buildOption(el) {
  const type = el.dataset.chartType
  const parsed = JSON.parse(el.dataset.series || "[]")

  if (type === "climb") {
    const results = JSON.parse(el.dataset.results || "[]")
    const yMin = parseInt(el.dataset.yMin, 10) || 0
    const yMax = parseInt(el.dataset.yMax, 10) || 120
    return climbOption(parsed, results, el.dataset.xMin, el.dataset.xMax, yMin, yMax)
  } else if (type === "winrate") {
    return winrateOption(parsed)
  } else if (type === "curve") {
    return curveOption(parsed)
  } else if (type === "match_results") {
    return matchResultsOption(parsed)
  } else if (type === "percentile") {
    return percentileOption(parsed)
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
