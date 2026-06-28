<script setup lang="ts">
import { ref, computed, onMounted, watch, nextTick } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getDailyK, getStockBasic } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import KLineZoomControls from '../components/KLineZoomControls.vue'
import { useKLineZoom } from '../composables/useKLineZoom'
import type { DailyKRecord } from '../api'
import * as echarts from 'echarts'

const route = useRoute()
const router = useRouter()
const symbol = computed(() => route.params.symbol as string)
const records = ref<DailyKRecord[]>([])
const loading = ref(false)
const error = ref('')
const stockName = ref('')

// Date range
const startDate = ref('')
const endDate = ref('')
const allDataStartDate = '1990-01-01'

// Date presets
const datePresets = [
  { label: '近3月', months: 3 },
  { label: '近半年', months: 6 },
  { label: '近1年', months: 12 },
  { label: '近3年', months: 36 },
  { label: '全部', months: 0 },
]

function setPreset(months: number) {
  const end = new Date()
  endDate.value = formatDate(end)
  if (months === 0) {
    startDate.value = allDataStartDate
  } else {
    const start = new Date()
    start.setMonth(start.getMonth() - months)
    startDate.value = formatDate(start)
  }
  loadData()
}

function formatDate(d: Date): string {
  return d.toISOString().split('T')[0]
}

// Search
const searchInput = ref(symbol.value)

function doSearch() {
  const sym = searchInput.value.trim()
  if (sym) {
    router.push(`/history/${sym}`)
  }
}

// Load data
async function loadData() {
  loading.value = true
  error.value = ''
  try {
    const [res, basic] = await Promise.allSettled([
      getDailyK(symbol.value, startDate.value, endDate.value),
      getStockBasic(symbol.value),
    ])
    if (res.status === 'fulfilled') {
      records.value = res.value.data
    } else {
      error.value = res.reason?.response?.data?.detail || '加载失败'
      records.value = []
    }
    if (basic.status === 'fulfilled') {
      stockName.value = (basic.value as any).data?.name || ''
    }
  } catch (e: any) {
    error.value = e.response?.data?.detail || '加载失败'
    records.value = []
  }
  loading.value = false
  // Wait for DOM to render chart div (after loading=false), then build chart
  nextTick(() => buildChart())
}

onMounted(() => {
  // Default: 1 year
  const now = new Date()
  const yearAgo = new Date()
  yearAgo.setFullYear(yearAgo.getFullYear() - 1)
  startDate.value = formatDate(yearAgo)
  endDate.value = formatDate(now)
  loadData()
})

// Reload when symbol or dates change
watch(
  () => route.fullPath,
  () => {
    searchInput.value = symbol.value
    loadData()
  }
)

// ECharts
const chartRef = ref<HTMLElement | null>(null)
let chart: echarts.ECharts | null = null
const { canZoomIn, canZoomOut, getDataZoomOption, panKLineByWheel, setCategories, syncZoomWindow, zoomKLine } = useKLineZoom(() => chart)

function buildChart() {
  if (!chartRef.value || records.value.length === 0) return

  if (!chart) {
    chart = echarts.init(chartRef.value, undefined, { renderer: 'canvas' })
    chart.on('datazoom', syncZoomWindow)
  }

  const sorted = [...records.value].sort((a, b) => a.date.localeCompare(b.date))

  const dates = sorted.map(r => r.date)
  const ohlc = sorted.map(r => [r.open, r.close, r.low, r.high])
  const volumes = sorted.map(r => r.volume || 0)
  const changes = sorted.map(r => (r.close || 0) - (r.open || 0))

  // Calculate MA
  const closes = sorted.map(r => r.close || 0)
  const ma5 = calcMA(closes, 5)
  const ma10 = calcMA(closes, 10)
  const ma20 = calcMA(closes, 20)
  const ma60 = calcMA(closes, 60)

  const upColor = '#ff3b3b'
  const downColor = '#00c853'
  const zoomWindow = setCategories(dates)

  const option: echarts.EChartsOption = {
    animation: false,
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      axisPointer: {
        type: 'cross',
        crossStyle: { color: '#00fff760' },
        lineStyle: { color: '#00fff760' },
      },
      formatter: (params: any) => {
        if (!params || params.length === 0) return ''
        const idx = params[0].dataIndex
        const r = sorted[idx]
        const change = r.change_pct != null ? r.change_pct.toFixed(2) : '--'
        const changeColor = (r.close || 0) >= (r.open || 0) ? upColor : downColor
        return `
          <div style="font-family: monospace; font-size: 12px; color: #f0e6ff;">
            <b style="color: #00fff7">${r.date}</b><br/>
            开盘: <span style="color: ${changeColor}">${r.open?.toFixed(2) ?? '--'}</span><br/>
            收盘: <span style="color: ${changeColor}">${r.close?.toFixed(2) ?? '--'}</span><br/>
            最高: <span style="color: ${changeColor}">${r.high?.toFixed(2) ?? '--'}</span><br/>
            最低: <span style="color: ${changeColor}">${r.low?.toFixed(2) ?? '--'}</span><br/>
            成交量: ${(r.volume ?? 0).toFixed(0)}<br/>
            涨跌幅: <span style="color: ${changeColor}">${change}%</span>
          </div>
        `
      },
    },
    axisPointer: {
      link: [{ xAxisIndex: 'all' }],
    },
    grid: [
      { left: 60, right: 30, top: 20, height: '55%' },
      { left: 60, right: 30, top: '72%', height: '20%' },
    ],
    xAxis: [
      {
        type: 'category',
        data: dates,
        boundaryGap: true,
        axisLine: { lineStyle: { color: '#3a2a6a' } },
        axisLabel: { color: '#8070b0', fontFamily: 'VT323', fontSize: 12 },
        splitLine: { show: false },
        gridIndex: 0,
      },
      {
        type: 'category',
        data: dates,
        boundaryGap: true,
        axisLine: { lineStyle: { color: '#3a2a6a' } },
        axisLabel: { show: false },
        splitLine: { show: false },
        gridIndex: 1,
      },
    ],
    yAxis: [
      {
        scale: true,
        splitArea: { show: false },
        splitLine: { lineStyle: { color: '#1a1a3a' } },
        axisLine: { lineStyle: { color: '#3a2a6a' } },
        axisLabel: { color: '#8070b0', fontFamily: 'VT323', fontSize: 12 },
        gridIndex: 0,
      },
      {
        scale: true,
        splitArea: { show: false },
        splitLine: { show: false },
        axisLine: { lineStyle: { color: '#3a2a6a' } },
        axisLabel: { show: false },
        gridIndex: 1,
      },
    ],
    dataZoom: [
      getDataZoomOption([0, 1]),
    ],
    series: [
      // Candlestick
      {
        name: '日K',
        type: 'candlestick',
        data: ohlc,
        itemStyle: {
          color: upColor,
          color0: downColor,
          borderColor: upColor,
          borderColor0: downColor,
        },
        barMaxWidth: 20,
        xAxisIndex: 0,
        yAxisIndex: 0,
      },
      // MA5
      {
        name: 'MA5',
        type: 'line',
        data: ma5,
        smooth: true,
        symbol: 'none',
        lineStyle: { width: 1, color: '#ffd700' },
        xAxisIndex: 0,
        yAxisIndex: 0,
      },
      // MA10
      {
        name: 'MA10',
        type: 'line',
        data: ma10,
        smooth: true,
        symbol: 'none',
        lineStyle: { width: 1, color: '#bf00ff' },
        xAxisIndex: 0,
        yAxisIndex: 0,
      },
      // MA20
      {
        name: 'MA20',
        type: 'line',
        data: ma20,
        smooth: true,
        symbol: 'none',
        lineStyle: { width: 1, color: '#00fff7' },
        xAxisIndex: 0,
        yAxisIndex: 0,
      },
      // MA60
      {
        name: 'MA60',
        type: 'line',
        data: ma60,
        smooth: true,
        symbol: 'none',
        lineStyle: { width: 1, color: '#ff6ec7' },
        xAxisIndex: 0,
        yAxisIndex: 0,
      },
      // Volume
      {
        name: '成交量',
        type: 'bar',
        data: volumes.map((v, i) => ({
          value: v,
          itemStyle: {
            color: changes[i] >= 0 ? upColor : downColor,
          },
        })),
        xAxisIndex: 1,
        yAxisIndex: 1,
        barMaxWidth: 20,
      },
    ],
    legend: {
      data: ['日K', 'MA5', 'MA10', 'MA20', 'MA60', '成交量'],
      top: 0,
      textStyle: { color: '#8070b0', fontFamily: 'VT323', fontSize: 12 },
      inactiveColor: '#3a2a6a',
    },
  }

  chart.setOption(option, true) // true = notMerge, replace all data
  chart.dispatchAction({
    type: 'dataZoom',
    dataZoomId: 'kline-inside-zoom',
    startValue: zoomWindow.startValue,
    endValue: zoomWindow.endValue,
  } as any)
  chart.resize()
}

function calcMA(data: number[], period: number): (number | null)[] {
  return data.map((_, i) => {
    if (i < period - 1) return null
    const slice = data.slice(i - period + 1, i + 1)
    return slice.reduce((a, b) => a + b, 0) / period
  })
}

function fmtVolume(v: number | null): string {
  if (v == null) return '--'
  if (v >= 100000000) return (v / 100000000).toFixed(2) + '亿'
  if (v >= 10000) return (v / 10000).toFixed(2) + '万'
  return v.toFixed(0)
}

function changeColor(val: number | null): string {
  if (val == null) return '#8070b0'
  return val >= 0 ? '#ff3b3b' : '#00c853'
}

function changeIcon(val: number | null): string {
  if (val == null) return ''
  return val >= 0 ? '↑' : '↓'
}

// Watch records to rebuild chart (handles cases where records change outside loadData)
watch(
  () => records.value.length,
  () => {
    nextTick(() => buildChart())
  }
)

// Resize
window.addEventListener('resize', () => chart?.resize())

// Sorted descending for table
const sortedDesc = computed(() => [...records.value].sort((a, b) => b.date.localeCompare(a.date)))
</script>

<template>
  <div class="container">
    <!-- Search & Controls -->
    <div class="vapor-card controls-card">
      <div class="search-row">
        <input
          v-model="searchInput"
          class="vapor-input"
          placeholder="输入股票代码..."
          @keyup.enter="doSearch"
          style="width: 160px"
        />
        <button class="neon-btn primary" @click="doSearch" style="padding: 0.5rem 1.2rem; font-size: 0.8rem">查询</button>
      </div>

      <div class="date-row">
        <input type="date" v-model="startDate" class="vapor-input date-input" />
        <span class="date-sep">~</span>
        <input type="date" v-model="endDate" class="vapor-input date-input" />
        <button class="neon-btn" @click="loadData" style="padding: 0.5rem 1rem; font-size: 0.8rem">确定</button>
      </div>

      <div class="preset-row">
        <button
          v-for="preset in datePresets"
          :key="preset.label"
          class="preset-btn"
          @click="setPreset(preset.months)"
        >
          {{ preset.label }}
        </button>
      </div>
    </div>

    <!-- Loading overlay -->
    <div v-show="loading" class="loading-overlay">
      <div class="loading-glitch">LOADING K-LINE DATA...</div>
    </div>

    <!-- Error -->
    <div v-show="error" class="error-msg">
      <span>ERROR: {{ error }}</span>
    </div>

    <!-- Chart + Table -->
    <div v-show="!loading && !error && records.length > 0">
      <!-- Header -->
      <div class="stock-header">
        <span class="stock-symbol">{{ symbol }}</span>
        <span class="stock-name" v-if="stockName">{{ stockName }}</span>
        <span class="stock-count">{{ records.length }} 条记录</span>
      </div>

      <!-- K-Line Chart -->
      <CRTFrame title="DAILY K-LINE CHART" class="chart-card">
        <div class="chart-shell">
          <div ref="chartRef" class="chart-container" @wheel="panKLineByWheel"></div>
          <KLineZoomControls
            :can-zoom-in="canZoomIn"
            :can-zoom-out="canZoomOut"
            @zoom="zoomKLine"
          />
        </div>
      </CRTFrame>

      <!-- Data Table -->
      <CRTFrame title="PRICE DATA TABLE" class="table-card">
        <div class="table-wrapper">
          <table class="vapor-table kline-table">
            <thead>
              <tr>
                <th>日期</th>
                <th>开盘</th>
                <th>收盘</th>
                <th>最高</th>
                <th>最低</th>
                <th>成交量</th>
                <th>涨跌幅</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in sortedDesc" :key="r.date">
                <td>{{ r.date }}</td>
                <td :style="{ color: changeColor((r.close ?? 0) - (r.open ?? 0)) }">
                  {{ r.open?.toFixed(2) ?? '--' }}
                </td>
                <td :style="{ color: changeColor((r.close ?? 0) - (r.open ?? 0)) }">
                  {{ r.close?.toFixed(2) ?? '--' }}
                </td>
                <td :style="{ color: changeColor((r.close ?? 0) - (r.open ?? 0)) }">
                  {{ r.high?.toFixed(2) ?? '--' }}
                </td>
                <td :style="{ color: changeColor((r.close ?? 0) - (r.open ?? 0)) }">
                  {{ r.low?.toFixed(2) ?? '--' }}
                </td>
                <td>{{ fmtVolume(r.volume) }}</td>
                <td :style="{ color: changeColor(r.change_pct) }">
                  {{ r.change_pct != null ? `${r.change_pct >= 0 ? '+' : ''}${r.change_pct.toFixed(2)}% ${changeIcon(r.change_pct)}` : '--' }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </CRTFrame>
    </div>

    <!-- Empty -->
    <div v-show="!loading && !error && records.length === 0" class="empty-msg">
      <div style="font-family: var(--font-retro); color: #8070b0; font-size: 0.9rem; letter-spacing: 1px">
        无数据 — 请输入股票代码并查询
      </div>
    </div>
  </div>
</template>

<style scoped>
.controls-card {
  padding: 1.2rem;
  margin-bottom: 1.5rem;
}

.search-row {
  display: flex;
  align-items: center;
  gap: 0.8rem;
  margin-bottom: 0.8rem;
}

.date-row {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-bottom: 0.8rem;
}

.date-input {
  font-size: 0.9rem;
  padding: 0.4rem 0.6rem;
  color-scheme: dark;
}

.date-sep {
  color: #6050a0;
  font-size: 1.2rem;
}

.preset-row {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.preset-btn {
  font-family: var(--font-retro);
  font-size: 0.7rem;
  padding: 0.3rem 0.8rem;
  border: 1px solid #bf00ff40;
  background: transparent;
  color: #a090d0;
  cursor: pointer;
  border-radius: 2px;
  transition: all 0.2s ease;
  letter-spacing: 1px;
}

.preset-btn:hover {
  border-color: var(--neon-cyan);
  color: var(--neon-cyan);
  background: rgba(0, 255, 247, 0.05);
}

.stock-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1rem;
}

.stock-symbol {
  font-family: var(--font-retro);
  font-size: 1.2rem;
  color: var(--neon-cyan);
  text-shadow: 0 0 10px #00fff760;
}

.stock-name {
  font-family: var(--font-retro);
  font-size: 1rem;
  color: #a090d0;
}

.stock-count {
  font-family: var(--font-terminal);
  font-size: 1rem;
  color: #8070b0;
}

.chart-card {
  margin-bottom: 1.5rem;
}

.chart-container {
  width: 100%;
  height: 550px;
  cursor: grab;
  touch-action: pan-y;
}

.chart-container:active {
  cursor: grabbing;
}

.chart-shell {
  position: relative;
}

.table-card {
  margin-bottom: 1.5rem;
}

.table-wrapper {
  max-height: 500px;
  overflow-y: auto;
}

.kline-table th {
  position: sticky;
  top: 0;
  z-index: 1;
  background: var(--bg-purple);
}

.kline-table td {
  font-family: var(--font-terminal);
  font-size: 1rem;
  text-align: right;
}

.kline-table td:first-child {
  text-align: left;
}

.error-msg {
  text-align: center;
  padding: 3rem;
  font-family: var(--font-retro);
  font-size: 0.9rem;
  color: #ff4466;
  text-shadow: 0 0 10px #ff446660;
}

.empty-msg {
  text-align: center;
  padding: 4rem;
}

.loading-overlay {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 4rem;
}
</style>
