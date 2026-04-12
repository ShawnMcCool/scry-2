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

function climbOption(climbSeries, resultsSeries, xMin, xMax, yMin, yMax, matchDetails) {
  // Build timestamp → result lookup for coloring dots
  const resultByTimestamp = new Map()
  if (resultsSeries) {
    for (const [ts, value] of resultsSeries) {
      resultByTimestamp.set(ts, value)
    }
  }

  // Color each data point: green for win, orange for loss, grey for no result
  const coloredData = climbSeries.map(([ts, score]) => {
    const result = resultByTimestamp.get(ts)
    const color =
      result > 0 ? "#22c55e" : result < 0 ? "#f97316" : "#9ca3af"
    return {value: [ts, score, result ?? null], itemStyle: {color}}
  })

  const xBounds = xMin && xMax ? {min: xMin, max: xMax} : {}

  return {
    backgroundColor: "transparent",
    grid: {left: 80, right: 20, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        if (!params.length) return ""
        const ts = params[0].value[0]
        const date = new Date(ts).toLocaleString()
        const rank = rankLabel(params[0].value[1])
        const resultValue = params[0].value[2]
        const result = resultValue != null
          ? `<br/>${resultValue > 0 ? "<span style='color:#22c55e'>Win</span>" : "<span style='color:#f97316'>Loss</span>"}`
          : ""

        // Match details from server-side correlation
        const detail = matchDetails[ts]
        let detailHtml = ""
        if (detail) {
          const lines = []
          if (detail.deck_name) lines.push(`Deck: ${detail.deck_name}`)
          if (detail.deck_colors) lines.push(`Colors: ${formatColors(detail.deck_colors)}`)
          if (detail.opponent) lines.push(`vs ${detail.opponent}`)
          if (detail.num_games) lines.push(detail.num_games === 1 ? "BO1" : `BO3 (${detail.num_games} games)`)
          if (detail.on_play != null) lines.push(detail.on_play ? "On the play" : "On the draw")
          if (detail.duration != null) lines.push(`${Math.round(detail.duration / 60)} min`)
          if (detail.event_name) lines.push(`<span style="color:#6b7280">${detail.event_name}</span>`)
          if (lines.length) detailHtml = "<br/>" + lines.join("<br/>")
        }

        return `${date}<br/><b>${rank}</b>${result}${detailHtml}`
      },
    },
    xAxis: {
      type: "time",
      ...xBounds,
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
    yAxis: {
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
    series: [
      {
        type: "line",
        step: "end",
        data: coloredData,
        smooth: false,
        symbol: "circle",
        symbolSize: 7,
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

const COLOR_SYMBOLS = {
  W: "⚪", U: "🔵", B: "⚫", R: "🔴", G: "🟢",
}

function formatColors(colorStr) {
  return colorStr
    .split("")
    .map(c => COLOR_SYMBOLS[c] || c)
    .join("")
}

function economyCurrencyOption(data) {
  const {gold = [], gems = []} = data

  return {
    backgroundColor: "transparent",
    grid: {left: 80, right: 80, top: 16, bottom: 40},
    tooltip: {
      trigger: "axis",
      formatter(params) {
        if (!params.length) return ""
        const date = new Date(params[0].value[0]).toLocaleString()
        const lines = params.map(p => {
          const val = p.value[1].toLocaleString()
          return `${p.marker} ${p.seriesName}: <b>${val}</b>`
        })
        return `${date}<br/>${lines.join("<br/>")}`
      },
    },
    xAxis: {
      type: "time",
      axisLabel: {color: "#9ca3af", fontSize: 11},
      axisLine: {lineStyle: {color: "#374151"}},
      splitLine: {show: false},
    },
    yAxis: [
      {
        type: "value",
        name: "Gold",
        nameTextStyle: {color: "#f59e0b", fontSize: 11},
        axisLabel: {color: "#f59e0b", fontSize: 11, formatter: v => v.toLocaleString()},
        axisLine: {lineStyle: {color: "#374151"}},
        splitLine: {lineStyle: {color: "#1f2937"}},
      },
      {
        type: "value",
        name: "Gems",
        nameTextStyle: {color: "#06b6d4", fontSize: 11},
        axisLabel: {color: "#06b6d4", fontSize: 11, formatter: v => v.toLocaleString()},
        axisLine: {lineStyle: {color: "#374151"}},
        splitLine: {show: false},
      },
    ],
    series: [
      {
        name: "Gold",
        type: "line",
        step: "end",
        yAxisIndex: 0,
        data: gold,
        symbol: "circle",
        symbolSize: 6,
        lineStyle: {color: "#f59e0b", width: 2},
        itemStyle: {color: "#f59e0b"},
        areaStyle: {color: "rgba(245,158,11,0.08)"},
      },
      {
        name: "Gems",
        type: "line",
        step: "end",
        yAxisIndex: 1,
        data: gems,
        symbol: "circle",
        symbolSize: 6,
        lineStyle: {color: "#06b6d4", width: 2},
        itemStyle: {color: "#06b6d4"},
        areaStyle: {color: "rgba(6,182,212,0.08)"},
      },
    ],
  }
}

function economyWildcardsOption(data) {
  const {common = [], uncommon = [], rare = [], mythic = []} = data

  const RARITY_COLORS = {
    Common: "#9ca3af",
    Uncommon: "#3b82f6",
    Rare: "#f59e0b",
    Mythic: "#dc2626",
  }

  return {
    backgroundColor: "transparent",
    grid: {left: 50, right: 20, top: 36, bottom: 40},
    legend: {
      top: 0,
      textStyle: {color: "#9ca3af", fontSize: 11},
      itemWidth: 12,
      itemHeight: 8,
    },
    tooltip: {
      trigger: "axis",
      formatter(params) {
        if (!params.length) return ""
        const date = new Date(params[0].value[0]).toLocaleString()
        const lines = params.map(p => `${p.marker} ${p.seriesName}: <b>${p.value[1]}</b>`)
        return `${date}<br/>${lines.join("<br/>")}`
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
    series: Object.entries({Common: common, Uncommon: uncommon, Rare: rare, Mythic: mythic}).map(
      ([name, seriesData]) => ({
        name,
        type: "line",
        step: "end",
        data: seriesData,
        symbol: "circle",
        symbolSize: 6,
        lineStyle: {color: RARITY_COLORS[name], width: 2},
        itemStyle: {color: RARITY_COLORS[name]},
        areaStyle: {color: RARITY_COLORS[name].replace(")", ",0.06)").replace("rgb", "rgba").replace("#", "")},
      })
    ).map(s => {
      // Convert hex color to rgba for areaStyle
      const hex = s.lineStyle.color
      const r = parseInt(hex.slice(1, 3), 16)
      const g = parseInt(hex.slice(3, 5), 16)
      const b = parseInt(hex.slice(5, 7), 16)
      s.areaStyle = {color: `rgba(${r},${g},${b},0.06)`}
      return s
    }),
  }
}

function buildOption(el) {
  const type = el.dataset.chartType
  const parsed = JSON.parse(el.dataset.series || "[]")

  if (type === "climb") {
    const results = JSON.parse(el.dataset.results || "[]")
    const matchDetails = JSON.parse(el.dataset.matchDetails || "{}")
    const yMin = parseInt(el.dataset.yMin, 10) || 0
    const yMax = parseInt(el.dataset.yMax, 10) || 120
    return climbOption(parsed, results, el.dataset.xMin, el.dataset.xMax, yMin, yMax, matchDetails)
  } else if (type === "winrate") {
    return winrateOption(parsed)
  } else if (type === "curve") {
    return curveOption(parsed)
  } else if (type === "match_results") {
    return matchResultsOption(parsed)
  } else if (type === "percentile") {
    return percentileOption(parsed)
  } else if (type === "economy_currency") {
    return economyCurrencyOption(parsed)
  } else if (type === "economy_wildcards") {
    return economyWildcardsOption(parsed)
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
