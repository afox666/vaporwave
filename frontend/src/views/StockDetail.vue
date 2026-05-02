<script setup lang="ts">
import { ref, onMounted, computed, watch, nextTick } from 'vue'
import { useRoute } from 'vue-router'
import { getStockFull, getDailyK } from '../api'
import * as echarts from 'echarts'
import CRTFrame from '../components/CRTFrame.vue'
import NeonBar from '../components/NeonBar.vue'
import type { DailyKRecord } from '../api'

const route = useRoute()
const symbol = computed(() => route.params.symbol as string)
const data = ref<any>(null)
const kRecords = ref<DailyKRecord[]>([])
const loading = ref(true)
const errorMessage = ref('')
const chartRef = ref<HTMLElement | null>(null)
let chart: echarts.ECharts | null = null

function getQueryString(name: string): string | null {
  const value = route.query[name]
  if (Array.isArray(value)) return value[0] ?? null
  return value ?? null
}

function getQueryNumber(name: string): number | null {
  const value = getQueryString(name)
  if (value == null || value === '') return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

function getRouteContext() {
  return {
    name: getQueryString('name'),
    price: getQueryNumber('price'),
    score: getQueryNumber('score'),
  }
}

function formatScore(score: unknown): string {
  const parsed = Number(score)
  return Number.isFinite(parsed) ? `${parsed.toFixed(0)}/100` : '--/100'
}

function normalizeStockFull(raw: any, sym: string) {
  const context = getRouteContext()
  const hasRawScore = raw && Object.prototype.hasOwnProperty.call(raw, 'score') && raw.score != null
  const normalized = {
    symbol: raw?.symbol || sym,
    score: hasRawScore ? Number(raw.score) : context.score,
    basic: raw?.basic && typeof raw.basic === 'object' ? { ...raw.basic } : {},
    profile: raw?.profile && typeof raw.profile === 'object' ? { ...raw.profile } : {},
    valuation: raw?.valuation && typeof raw.valuation === 'object' ? { ...raw.valuation } : {},
    technical: raw?.technical && typeof raw.technical === 'object' ? raw.technical : {},
    industry: raw?.industry && typeof raw.industry === 'object' ? raw.industry : {},
    futures: raw?.futures && typeof raw.futures === 'object' ? raw.futures : {},
    kline: Array.isArray(raw?.kline) ? raw.kline : [],
  }

  // The Tauri sidecar currently returns a compact shape:
  // { symbol, name, latest, kline, pe_ttm }. Normalize it for this view.
  if (!normalized.basic['股票简称']) {
    normalized.basic['股票简称'] = raw?.name || context.name || normalized.symbol
  }
  const latest = raw?.latest ?? context.price
  if (latest != null && normalized.basic['最新'] == null) {
    normalized.basic['最新'] = latest
  }

  if (!normalized.valuation || typeof normalized.valuation !== 'object') {
    normalized.valuation = {}
  }
  if (!normalized.valuation.price && latest != null) {
    normalized.valuation.price = {
      current: latest,
      percentile: 0,
      hist_low: latest,
      hist_high: latest,
    }
  }
  if (!normalized.valuation.pe && raw?.pe_ttm != null) {
    normalized.valuation.pe = {
      current: raw.pe_ttm,
      percentile: 0,
      is_loss: false,
    }
  }

  return normalized
}

async function loadStock(sym: string) {
  loading.value = true
  errorMessage.value = ''
  if (chart) {
    chart.dispose()
    chart = null
  }
  kRecords.value = []
  data.value = null

  try {
    const [fullRes, kRes] = await Promise.all([
      getStockFull(sym).catch((e) => {
        console.error(e)
        return { data: null }
      }),
      getDailyK(sym).catch((e) => {
        console.error(e)
        return { data: [] }
      }),
    ])

    const normalized = normalizeStockFull(fullRes.data, sym)
    data.value = normalized
    kRecords.value = kRes.data?.length ? kRes.data : normalized.kline

    if (!fullRes.data && kRecords.value.length === 0) {
      errorMessage.value = '无法获取该股票详情数据'
    }
  } catch (e) {
    console.error(e)
    errorMessage.value = '加载股票详情失败'
  }
  loading.value = false
  nextTick(() => buildChart())
}

onMounted(async () => {
  await loadStock(symbol.value)
})

// Reload data when navigating to a different stock
watch(symbol, async (newSym) => {
  await loadStock(newSym)
})

const scoreColor = computed(() => {
  if (data.value?.score == null) return '#8070b0'
  const s = data.value.score
  if (s >= 90) return '#ff3b3b'
  if (s >= 70) return '#00fff7'
  if (s >= 50) return '#ffd700'
  return '#00c853'
})

const techTags = computed(() => {
  if (!data.value?.technical) return []
  const t = data.value.technical
  const tags: { label: string; color: string }[] = []
  if (t.trend?.ma_arrangement) {
    const c = t.trend.ma_arrangement === '多头排列' ? '#ff3b3b' : t.trend.ma_arrangement === '空头排列' ? '#00c853' : '#ffd700'
    tags.push({ label: t.trend.ma_arrangement, color: c })
  }
  if (t.indicators?.macd?.trend) {
    const c = t.indicators.macd.trend.includes('金叉') ? '#ff3b3b' : t.indicators.macd.trend.includes('死叉') ? '#00c853' : '#00fff7'
    tags.push({ label: `MACD: ${t.indicators.macd.trend}`, color: c })
  }
  if (t.indicators?.rsi) {
    const c = t.indicators.rsi.status === '超买' ? '#00c853' : t.indicators.rsi.status === '超卖' ? '#ff3b3b' : '#00fff7'
    tags.push({ label: `RSI: ${t.indicators.rsi.value}`, color: c })
  }
  if (t.position) {
    tags.push({ label: `位置: ${t.position}`, color: '#bf00ff' })
  }
  return tags
})

function calcMA(data: number[], period: number): (number | null)[] {
  return data.map((_, i) => {
    if (i < period - 1) return null
    return data.slice(i - period + 1, i + 1).reduce((a, b) => a + b, 0) / period
  })
}

function buildChart() {
  if (!chartRef.value || kRecords.value.length === 0) return

  if (!chart) {
    chart = echarts.init(chartRef.value, undefined, { renderer: 'canvas' })
  }

  const sorted = [...kRecords.value].sort((a, b) => a.date.localeCompare(b.date))
  const dates = sorted.map(r => r.date)
  const ohlc = sorted.map(r => [r.open, r.close, r.low, r.high])
  const volumes = sorted.map(r => r.volume || 0)
  const changes = sorted.map(r => (r.close || 0) - (r.open || 0))

  const closes = sorted.map(r => r.close || 0)
  const ma5 = calcMA(closes, 5)
  const ma10 = calcMA(closes, 10)
  const ma20 = calcMA(closes, 20)

  const upColor = '#ff3b3b'
  const downColor = '#00c853'

  const option: echarts.EChartsOption = {
    animation: false,
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      axisPointer: { type: 'cross', crossStyle: { color: '#00fff760' }, lineStyle: { color: '#00fff760' } },
      formatter: (params: any) => {
        if (!params || params.length === 0) return ''
        const idx = params[0].dataIndex
        const r = sorted[idx]
        const change = r.change_pct != null ? r.change_pct.toFixed(2) : '--'
        const c = (r.close || 0) >= (r.open || 0) ? upColor : downColor
        return `<div style="font-family: monospace; font-size: 12px; color: #f0e6ff;">
          <b style="color: #00fff7">${r.date}</b><br/>
          开盘: <span style="color: ${c}">${r.open?.toFixed(2) ?? '--'}</span><br/>
          收盘: <span style="color: ${c}">${r.close?.toFixed(2) ?? '--'}</span><br/>
          最高: <span style="color: ${c}">${r.high?.toFixed(2) ?? '--'}</span><br/>
          最低: <span style="color: ${c}">${r.low?.toFixed(2) ?? '--'}</span><br/>
          成交量: ${(r.volume ?? 0).toFixed(0)}<br/>
          涨跌幅: <span style="color: ${c}">${change}%</span>
        </div>`
      },
    },
    axisPointer: { link: [{ xAxisIndex: 'all' }] },
    grid: [
      { left: 50, right: 20, top: 10, height: '55%' },
      { left: 50, right: 20, top: '72%', height: '20%' },
    ],
    xAxis: [
      { type: 'category', data: dates, boundaryGap: true, axisLine: { lineStyle: { color: '#3a2a6a' } }, axisLabel: { color: '#8070b0', fontFamily: 'VT323', fontSize: 10 }, splitLine: { show: false }, gridIndex: 0 },
      { type: 'category', data: dates, boundaryGap: true, axisLine: { lineStyle: { color: '#3a2a6a' } }, axisLabel: { show: false }, splitLine: { show: false }, gridIndex: 1 },
    ],
    yAxis: [
      { scale: true, splitArea: { show: false }, splitLine: { lineStyle: { color: '#1a1a3a' } }, axisLine: { lineStyle: { color: '#3a2a6a' } }, axisLabel: { color: '#8070b0', fontFamily: 'VT323', fontSize: 10 }, gridIndex: 0 },
      { scale: true, splitArea: { show: false }, splitLine: { show: false }, axisLine: { lineStyle: { color: '#3a2a6a' } }, axisLabel: { show: false }, gridIndex: 1 },
    ],
    dataZoom: [
      { type: 'inside', xAxisIndex: [0, 1], start: 60, end: 100, minValueSpan: 5 },
      { type: 'slider', xAxisIndex: [0, 1], bottom: 5, start: 60, end: 100, borderColor: '#3a2a6a', backgroundColor: '#0a0a1a', fillerColor: '#bf00ff15', handleStyle: { color: '#bf00ff' }, textStyle: { color: '#8070b0', fontFamily: 'VT323', fontSize: 10 }, height: 16 },
    ],
    series: [
      { name: '日K', type: 'candlestick', data: ohlc, itemStyle: { color: upColor, color0: downColor, borderColor: upColor, borderColor0: downColor }, barMaxWidth: 16, xAxisIndex: 0, yAxisIndex: 0 },
      { name: 'MA5', type: 'line', data: ma5, smooth: true, symbol: 'none', lineStyle: { width: 1, color: '#ffd700' }, xAxisIndex: 0, yAxisIndex: 0 },
      { name: 'MA10', type: 'line', data: ma10, smooth: true, symbol: 'none', lineStyle: { width: 1, color: '#bf00ff' }, xAxisIndex: 0, yAxisIndex: 0 },
      { name: 'MA20', type: 'line', data: ma20, smooth: true, symbol: 'none', lineStyle: { width: 1, color: '#00fff7' }, xAxisIndex: 0, yAxisIndex: 0 },
      { name: '成交量', type: 'bar', data: volumes.map((v, i) => ({ value: v, itemStyle: { color: changes[i] >= 0 ? upColor : downColor } })), xAxisIndex: 1, yAxisIndex: 1, barMaxWidth: 16 },
    ],
    legend: { data: ['日K', 'MA5', 'MA10', 'MA20', '成交量'], top: 0, textStyle: { color: '#8070b0', fontFamily: 'VT323', fontSize: 10 }, inactiveColor: '#3a2a6a' },
  }

  chart.setOption(option, true)
  chart.resize()
}

window.addEventListener('resize', () => chart?.resize())
</script>

<template>
  <div class="container">
    <div v-if="loading" class="loading-glitch">LOADING ANALYSIS...</div>

    <template v-else-if="data">
      <!-- Header -->
      <div class="flex-between mb-3">
        <div>
          <h2 class="neon-title" style="text-align: left; font-size: 1.4rem">
            {{ data.basic['股票简称'] || symbol }} ({{ symbol }})
          </h2>
          <p class="neon-subtitle mt-1">
            ¥{{ data.valuation.price?.current || data.basic['最新'] || '--' }}
            <span class="neon-tag" :style="{ color: scoreColor, borderColor: scoreColor, marginLeft: '1rem' }">
              综合评分: {{ formatScore(data.score) }}
            </span>
          </p>
        </div>
      </div>

      <!-- Technical Indicators -->
      <CRTFrame title="TECHNICAL ANALYSIS" class="mb-3">
        <div class="flex-center" style="flex-wrap: wrap">
          <span
            v-for="tag in techTags"
            :key="tag.label"
            class="neon-tag"
            :style="{ color: tag.color, borderColor: tag.color }"
          >
            {{ tag.label }}
          </span>
        </div>
        <div v-if="data.technical?.suggestion" class="mt-2" style="color: #a090d0; font-size: 1rem">
          💡 {{ data.technical.suggestion }}
        </div>

        <!-- K-Line Chart -->
        <div class="kline-chart-wrapper">
          <div ref="chartRef" class="kline-chart"></div>
        </div>
      </CRTFrame>

      <div class="grid-2">
        <!-- Valuation -->
        <CRTFrame title="VALUATION">
          <div v-if="data.valuation.price">
            <NeonBar :value="data.valuation.price.percentile || 0" label="价格百分位" color="#ff007f" />
            <div class="detail-row">
              <span>当前</span><span style="color: var(--hot-yellow)">¥{{ data.valuation.price.current }}</span>
            </div>
            <div class="detail-row">
              <span>历史区间</span><span>¥{{ data.valuation.price.hist_low }} - ¥{{ data.valuation.price.hist_high }}</span>
            </div>
          </div>
          <div v-if="data.valuation.pe && !data.valuation.pe.is_loss" class="mt-2">
            <NeonBar :value="data.valuation.pe.percentile || 0" label="PE百分位" color="#bf00ff" />
            <div class="detail-row">
              <span>PE(TTM)</span><span style="color: var(--neon-cyan)">{{ data.valuation.pe.current }}</span>
            </div>
          </div>
          <div v-if="data.valuation.pe?.is_loss" class="mt-2" style="color: #ff4466">
            ⚠️ 公司当前处于亏损状态
          </div>
        </CRTFrame>

        <!-- Basic Info -->
        <CRTFrame title="BASIC INFO">
          <div class="detail-row" v-for="(val, key) in data.basic" :key="key">
            <span>{{ key }}</span><span style="color: #d0c0f0">{{ val }}</span>
          </div>
        </CRTFrame>

        <!-- Industry -->
        <CRTFrame title="INDUSTRY" v-if="data.industry && Object.keys(data.industry).length > 0">
          <div class="detail-row">
            <span>行业</span><span>{{ data.industry.industry_name }}</span>
          </div>
          <div class="detail-row">
            <span>排名</span><span>{{ data.industry.rank_in_industry || '--' }}</span>
          </div>
          <div class="detail-row">
            <span>行业平均涨跌</span><span>{{ data.industry.industry_avg_change }}%</span>
          </div>
          <div v-if="data.industry.relative_performance != null" class="detail-row">
            <span>相对表现</span>
            <span :style="{ color: data.industry.relative_performance >= 0 ? '#ff3b3b' : '#00c853' }">
              {{ data.industry.relative_performance }}%
            </span>
          </div>
          <div v-if="data.industry.top5_peers?.length > 0" class="mt-2">
            <div style="color: #8070b0; font-size: 0.9rem; margin-bottom: 0.5rem">行业领涨:</div>
            <div v-for="peer in data.industry.top5_peers.slice(0, 3)" :key="peer['代码']" class="detail-row">
              <span>{{ peer['名称'] }}</span><span :style="{ color: peer['涨跌幅'] >= 0 ? '#ff3b3b' : '#00c853' }">{{ peer['涨跌幅'] }}%</span>
            </div>
          </div>
        </CRTFrame>

        <!-- Company Profile -->
        <CRTFrame title="COMPANY" v-if="data.profile && data.profile['公司名称']">
          <div class="detail-row">
            <span>公司名称</span><span>{{ data.profile['公司名称'] }}</span>
          </div>
          <div v-if="data.profile['主营业务']" class="mt-2">
            <div style="color: #8070b0; font-size: 0.9rem">主营业务</div>
            <div style="color: #d0c0f0; font-size: 0.95rem; margin-top: 0.3rem; line-height: 1.5">
              {{ data.profile['主营业务'] }}
            </div>
          </div>
        </CRTFrame>
      </div>
    </template>

    <div v-else class="loading-glitch">{{ errorMessage || '无法获取数据' }}</div>
  </div>
</template>

<style scoped>
.detail-row {
  display: flex;
  justify-content: space-between;
  padding: 0.4rem 0;
  border-bottom: 1px solid #ff007f10;
  font-family: var(--font-terminal);
  font-size: 1rem;
}

.detail-row:first-child > span:first-child {
  color: #8070b0;
}

.detail-row > span:first-child {
  color: #8070b0;
}

.kline-chart-wrapper {
  margin-top: 1rem;
}

.kline-chart {
  width: 100%;
  height: 400px;
}
</style>
