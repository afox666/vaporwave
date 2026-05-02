<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount, computed, nextTick, watch } from 'vue'
import * as echarts from 'echarts'
import { cancelBacktestTask, createBacktestTask, getBacktestTask, getFactors, listBacktestTasks, runBacktest } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type { FactorInfo, BacktestRequestConfig, BacktestResult, BacktestTaskStatus } from '../api'

const factors = ref<FactorInfo[]>([])
const loading = ref(false)
const result = ref<BacktestResult | null>(null)
const errorMessage = ref('')
const taskId = ref('')
const taskStatus = ref<BacktestTaskStatus | null>(null)
const expandedHoldingRows = ref<Set<string>>(new Set())
const selectedResearchFactor = ref('')

const netValueChartRef = ref<HTMLElement | null>(null)
const drawdownChartRef = ref<HTMLElement | null>(null)
const costChartRef = ref<HTMLElement | null>(null)
const icChartRef = ref<HTMLElement | null>(null)
const quintileChartRef = ref<HTMLElement | null>(null)

let netValueChart: echarts.ECharts | null = null
let drawdownChart: echarts.ECharts | null = null
let costChart: echarts.ECharts | null = null
let icChart: echarts.ECharts | null = null
let quintileChart: echarts.ECharts | null = null
let taskPollTimer: ReturnType<typeof window.setTimeout> | null = null
const LAST_BACKTEST_TASK_KEY = 'vaporwave:lastBacktestTaskId'

// Form
const selectedFactors = ref<string[]>([])
const startDate = ref('2024-01-01')
const endDate = ref('2025-12-31')
const rebalancePeriod = ref(20)
const topPct = ref(0.2)
const poolSize = ref(100)
const poolMode = ref('dynamic')
const commissionRate = ref(0.0003)
const stampTaxRate = ref(0.0005)
const slippageRate = ref(0.0002)
const minAmount = ref(10000000)
const minListedDays = ref(60)
const limitPct = ref(9.8)
const executionPrice = ref('next_open')

// Group factors by category
const groupedFactors = computed(() => {
  const groups: Record<string, FactorInfo[]> = {}
  for (const f of factors.value) {
    if (!groups[f.category]) groups[f.category] = []
    groups[f.category].push(f)
  }
  return groups
})

const categoryLabels: Record<string, string> = {
  momentum: '动量因子',
  value: '价值因子',
  volatility: '波动率因子',
  volume: '成交量因子',
  technical: '技术指标因子',
}

const researchFactorNames = computed(() => Object.keys(result.value?.factor_research || {}))
const taskProgress = computed(() => Math.round((taskStatus.value?.progress || 0) * 100))
const taskProgressWidth = computed(() => `${Math.max(0, Math.min(100, taskProgress.value))}%`)
const canCancelTask = computed(() => (
  loading.value
  && !!taskId.value
  && taskId.value !== 'sync'
  && taskStatus.value?.status !== 'cancelling'
))

function qualityStatusLabel(status?: string): string {
  if (status === 'pass') return '通过'
  if (status === 'warn') return '注意'
  if (status === 'fail') return '失败'
  return '--'
}

function toggleFactor(name: string) {
  const idx = selectedFactors.value.indexOf(name)
  if (idx >= 0) {
    selectedFactors.value.splice(idx, 1)
  } else {
    selectedFactors.value.push(name)
  }
}

async function runTest() {
  if (selectedFactors.value.length === 0) {
    errorMessage.value = '请至少选择一个因子'
    return
  }
  stopTaskPolling()
  loading.value = true
  errorMessage.value = ''
  result.value = null
  taskId.value = ''
  taskStatus.value = null
  expandedHoldingRows.value = new Set()
  disposeCharts()

  const config = makeBacktestConfig()
  try {
    const task = await createBacktestTask(config)
    rememberBacktestTask(task.data.task_id)
    await handleTaskState(task.data)
  } catch (e: any) {
    if (shouldFallbackToSyncBacktest(e)) {
      await runSynchronousBacktest(config)
    } else {
      errorMessage.value = getErrorMessage(e)
      loading.value = false
    }
  }
}

function makeBacktestConfig(): BacktestRequestConfig {
  return {
    factors: [...selectedFactors.value],
    start_date: startDate.value,
    end_date: endDate.value,
    rebalance_period: rebalancePeriod.value,
    top_pct: topPct.value,
    pool_size: poolSize.value,
    pool_mode: poolMode.value,
    commission_rate: commissionRate.value,
    stamp_tax_rate: stampTaxRate.value,
    slippage_rate: slippageRate.value,
    min_amount: minAmount.value,
    min_listed_days: minListedDays.value,
    limit_pct: limitPct.value,
    execution_price: executionPrice.value,
  }
}

function getErrorMessage(e: any): string {
  return e?.response?.data?.detail || e?.message || '回测运行失败'
}

function shouldFallbackToSyncBacktest(e: any): boolean {
  const status = e?.response?.status
  const message = String(e?.message || '')
  return status === 404 || status === 405 || message.includes('HTTP 404') || message.includes('HTTP 405')
}

function stopTaskPolling() {
  if (taskPollTimer !== null) {
    window.clearTimeout(taskPollTimer)
    taskPollTimer = null
  }
}

function scheduleTaskPoll(id: string) {
  stopTaskPolling()
  taskPollTimer = window.setTimeout(() => {
    void pollBacktestTask(id)
  }, 900)
}

function rememberBacktestTask(id: string) {
  try {
    window.localStorage.setItem(LAST_BACKTEST_TASK_KEY, id)
  } catch {
    // localStorage may be unavailable in restricted webviews.
  }
}

function getRememberedBacktestTask(): string {
  try {
    return window.localStorage.getItem(LAST_BACKTEST_TASK_KEY) || ''
  } catch {
    return ''
  }
}

function applyBacktestConfigToForm(config: BacktestRequestConfig) {
  selectedFactors.value = Array.isArray(config.factors) ? [...config.factors] : []
  startDate.value = config.start_date || startDate.value
  endDate.value = config.end_date || endDate.value
  rebalancePeriod.value = config.rebalance_period ?? rebalancePeriod.value
  topPct.value = config.top_pct ?? topPct.value
  poolSize.value = config.pool_size ?? poolSize.value
  poolMode.value = config.pool_mode || poolMode.value
  commissionRate.value = config.commission_rate ?? commissionRate.value
  stampTaxRate.value = config.stamp_tax_rate ?? stampTaxRate.value
  slippageRate.value = config.slippage_rate ?? slippageRate.value
  minAmount.value = config.min_amount ?? minAmount.value
  minListedDays.value = config.min_listed_days ?? minListedDays.value
  limitPct.value = config.limit_pct ?? limitPct.value
  executionPrice.value = config.execution_price || executionPrice.value
}

async function handleTaskState(state: BacktestTaskStatus, showTerminalError = true, restoreForm = false) {
  taskId.value = state.task_id
  taskStatus.value = state

  if (state.task_id && state.task_id !== 'sync') {
    rememberBacktestTask(state.task_id)
  }
  if (restoreForm && state.request) {
    applyBacktestConfigToForm(state.request)
  }

  if (state.status === 'completed') {
    stopTaskPolling()
    if (!state.result) {
      errorMessage.value = '任务已完成但未返回结果'
      loading.value = false
      return
    }
    await applyBacktestResult(state.result)
    errorMessage.value = ''
    loading.value = false
    return
  }

  if (state.status === 'failed' || state.status === 'cancelled') {
    stopTaskPolling()
    if (showTerminalError) {
      errorMessage.value = state.error || state.message || '回测运行失败'
    }
    loading.value = false
    return
  }

  errorMessage.value = ''
  loading.value = true
  scheduleTaskPoll(state.task_id)
}

async function pollBacktestTask(id: string) {
  taskPollTimer = null
  if (!loading.value || taskId.value !== id) return
  try {
    const res = await getBacktestTask(id)
    await handleTaskState(res.data)
  } catch (e: any) {
    errorMessage.value = getErrorMessage(e)
    loading.value = false
  }
}

async function cancelTest() {
  if (!taskId.value || taskId.value === 'sync') return
  try {
    const res = await cancelBacktestTask(taskId.value)
    taskStatus.value = res.data
  } catch (e: any) {
    errorMessage.value = getErrorMessage(e)
  }
}

async function runSynchronousBacktest(config: BacktestRequestConfig) {
  const now = new Date().toISOString()
  taskId.value = 'sync'
  taskStatus.value = {
    task_id: 'sync',
    status: 'running',
    progress: 0.15,
    stage: 'sync',
    message: '使用同步回测接口',
    created_at: now,
    updated_at: now,
  }
  try {
    const res = await runBacktest(config)
    await applyBacktestResult(res.data)
    taskStatus.value = {
      ...taskStatus.value,
      status: 'completed',
      progress: 1,
      stage: 'done',
      message: '回测完成',
      updated_at: new Date().toISOString(),
    }
  } catch (e: any) {
    errorMessage.value = getErrorMessage(e)
  }
  loading.value = false
}

async function restoreLastBacktestTask() {
  const rememberedTaskId = getRememberedBacktestTask()
  if (rememberedTaskId) {
    try {
      const res = await getBacktestTask(rememberedTaskId)
      await handleTaskState(res.data, true, true)
      return
    } catch (e) {
      console.warn('restore remembered backtest task failed', e)
    }
  }

  try {
    const recent = await listBacktestTasks(1)
    const latest = recent.data[0]
    if (latest) {
      await handleTaskState(latest, false, true)
    }
  } catch (e) {
    console.warn('restore recent backtest task failed', e)
  }
}

async function applyBacktestResult(data: BacktestResult) {
  result.value = data
  selectedResearchFactor.value = Object.keys(data.factor_research || {})[0] || ''
  await nextTick()
  buildCharts()
}

function fmt(val: number | null | undefined): string {
  if (val == null) return '--'
  const sign = val >= 0 ? '+' : ''
  return `${sign}${(val * 100).toFixed(2)}%`
}

function fmtNum(val: number | null | undefined): string {
  if (val == null) return '--'
  return val.toFixed(2)
}

function fmtWeight(val: number | null | undefined): string {
  if (val == null) return '--'
  return `${(val * 100).toFixed(1)}%`
}

function fmtMoney(val: number | null | undefined): string {
  if (val == null) return '--'
  if (val >= 100000000) return `${(val / 100000000).toFixed(1)}亿`
  if (val >= 10000) return `${(val / 10000).toFixed(0)}万`
  return val.toFixed(0)
}

function toggleHoldingRow(date: string, event: Event) {
  const target = event.target as HTMLDetailsElement
  const next = new Set(expandedHoldingRows.value)
  if (target.open) {
    next.add(date)
  } else {
    next.delete(date)
  }
  expandedHoldingRows.value = next
}

function isHoldingExpanded(date: string): boolean {
  return expandedHoldingRows.value.has(date)
}

function chartBaseOption(): echarts.EChartsOption {
  return {
    backgroundColor: 'transparent',
    textStyle: { color: '#c8b8ff', fontFamily: 'var(--font-terminal)' },
    grid: { left: 54, right: 24, top: 36, bottom: 48 },
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(18, 8, 38, 0.94)',
      borderColor: '#bf00ff80',
      textStyle: { color: '#f0e8ff', fontFamily: 'var(--font-terminal)' },
      valueFormatter: value => typeof value === 'number' ? `${(value * 100).toFixed(2)}%` : String(value),
    },
    legend: {
      top: 4,
      textStyle: { color: '#a090d0', fontFamily: 'var(--font-terminal)' },
    },
    xAxis: {
      type: 'category',
      axisLine: { lineStyle: { color: '#6040a0' } },
      axisLabel: { color: '#8070b0' },
    },
    yAxis: {
      type: 'value',
      axisLine: { lineStyle: { color: '#6040a0' } },
      splitLine: { lineStyle: { color: '#bf00ff18' } },
      axisLabel: {
        color: '#8070b0',
        formatter: (value: number) => `${(value * 100).toFixed(0)}%`,
      },
    },
  }
}

function getOrInitChart(refEl: HTMLElement | null, current: echarts.ECharts | null): echarts.ECharts | null {
  if (!refEl) return null
  return current || echarts.init(refEl, undefined, { renderer: 'canvas' })
}

function buildCharts() {
  buildNetValueChart()
  buildDrawdownChart()
  buildCostChart()
  buildIcChart()
  buildQuintileChart()
  resizeCharts()
}

function buildNetValueChart() {
  const data = result.value?.portfolio || []
  if (!data.length) return
  netValueChart = getOrInitChart(netValueChartRef.value, netValueChart)
  if (!netValueChart) return
  const dates = data.map(row => row.date?.substring(0, 10))
  netValueChart.setOption({
    ...chartBaseOption(),
    legend: { ...(chartBaseOption().legend as object), data: ['策略净值', '基准净值', '超额净值'] },
    xAxis: { ...(chartBaseOption().xAxis as object), data: dates },
    yAxis: { ...(chartBaseOption().yAxis as object), axisLabel: { color: '#8070b0', formatter: (value: number) => value.toFixed(2) } },
    series: [
      { name: '策略净值', type: 'line', smooth: true, showSymbol: false, data: data.map(row => row.net_value ?? 1), lineStyle: { color: '#ff3b8d', width: 2 } },
      { name: '基准净值', type: 'line', smooth: true, showSymbol: false, data: data.map(row => row.benchmark_net_value ?? 1), lineStyle: { color: '#00fff7', width: 2 } },
      { name: '超额净值', type: 'line', smooth: true, showSymbol: false, data: data.map(row => row.excess_net_value ?? 1), lineStyle: { color: '#ffd166', width: 2 } },
    ],
  }, true)
}

function buildDrawdownChart() {
  const data = result.value?.portfolio || []
  if (!data.length) return
  drawdownChart = getOrInitChart(drawdownChartRef.value, drawdownChart)
  if (!drawdownChart) return
  drawdownChart.setOption({
    ...chartBaseOption(),
    legend: { ...(chartBaseOption().legend as object), data: ['回撤'] },
    xAxis: { ...(chartBaseOption().xAxis as object), data: data.map(row => row.date?.substring(0, 10)) },
    series: [
      {
        name: '回撤',
        type: 'line',
        smooth: true,
        showSymbol: false,
        data: data.map(row => row.drawdown ?? 0),
        lineStyle: { color: '#00c853', width: 2 },
        areaStyle: { color: 'rgba(0, 200, 83, 0.16)' },
      },
    ],
  }, true)
}

function buildCostChart() {
  const data = result.value?.portfolio || []
  if (!data.length) return
  costChart = getOrInitChart(costChartRef.value, costChart)
  if (!costChart) return
  costChart.setOption({
    ...chartBaseOption(),
    legend: { ...(chartBaseOption().legend as object), data: ['换手率', '交易成本'] },
    xAxis: { ...(chartBaseOption().xAxis as object), data: data.map(row => row.date?.substring(0, 10)) },
    series: [
      { name: '换手率', type: 'bar', data: data.map(row => row.turnover ?? 0), itemStyle: { color: '#bf00ff' } },
      { name: '交易成本', type: 'line', smooth: true, showSymbol: false, data: data.map(row => row.cost ?? 0), lineStyle: { color: '#ffd166', width: 2 } },
    ],
  }, true)
}

function buildIcChart() {
  const research = result.value?.factor_research || {}
  const names = Object.keys(research)
  if (!names.length) return
  icChart = getOrInitChart(icChartRef.value, icChart)
  if (!icChart) return
  const dates = Array.from(new Set(names.flatMap(name => research[name].ic_series.map(point => point.date?.substring(0, 10)))))
  icChart.setOption({
    ...chartBaseOption(),
    legend: { ...(chartBaseOption().legend as object), data: names },
    xAxis: { ...(chartBaseOption().xAxis as object), data: dates },
    yAxis: { ...(chartBaseOption().yAxis as object), min: -1, max: 1 },
    series: names.map((name, idx) => {
      const values = new Map(research[name].ic_series.map(point => [point.date?.substring(0, 10), point.ic]))
      const colors = ['#ff3b8d', '#00fff7', '#ffd166', '#7cff6b', '#b388ff', '#ff7a59']
      return {
        name,
        type: 'line',
        smooth: true,
        showSymbol: false,
        data: dates.map(date => values.get(date) ?? null),
        lineStyle: { color: colors[idx % colors.length], width: 2 },
      }
    }),
  }, true)
}

function buildQuintileChart() {
  const research = result.value?.factor_research || {}
  const current = selectedResearchFactor.value || Object.keys(research)[0]
  const item = research[current]
  if (!item) return
  quintileChart = getOrInitChart(quintileChartRef.value, quintileChart)
  if (!quintileChart) return
  quintileChart.setOption({
    ...chartBaseOption(),
    legend: { ...(chartBaseOption().legend as object), data: [current] },
    xAxis: { ...(chartBaseOption().xAxis as object), data: ['Q1', 'Q2', 'Q3', 'Q4', 'Q5'] },
    series: [
      {
        name: current,
        type: 'bar',
        data: item.quintile_returns,
        itemStyle: {
          color: (params: any) => Number(params.value) >= 0 ? '#ff3b8d' : '#00c853',
        },
      },
    ],
  }, true)
}

function resizeCharts() {
  netValueChart?.resize()
  drawdownChart?.resize()
  costChart?.resize()
  icChart?.resize()
  quintileChart?.resize()
}

function disposeCharts() {
  netValueChart?.dispose()
  drawdownChart?.dispose()
  costChart?.dispose()
  icChart?.dispose()
  quintileChart?.dispose()
  netValueChart = null
  drawdownChart = null
  costChart = null
  icChart = null
  quintileChart = null
}

function handleResize() {
  resizeCharts()
}

onMounted(async () => {
  try {
    const res = await getFactors()
    factors.value = res.data
  } catch (e) {
    console.error(e)
  }
  await restoreLastBacktestTask()
  window.addEventListener('resize', handleResize)
})

onBeforeUnmount(() => {
  stopTaskPolling()
  window.removeEventListener('resize', handleResize)
  disposeCharts()
})

watch(selectedResearchFactor, () => {
  nextTick(() => buildQuintileChart())
})
</script>

<template>
  <div class="container">
    <h2 class="section-title">&#x26A1; 因子回测控制台</h2>

    <div class="grid-2">
      <!-- Factor Selection -->
      <CRTFrame title="FACTOR SELECTION">
        <div v-for="(group, category) in groupedFactors" :key="category" class="mb-3">
          <div style="color: #8070b0; font-size: 0.9rem; margin-bottom: 0.5rem">
            {{ categoryLabels[category] || category }}
          </div>
          <div class="factor-toggles">
            <button
              v-for="f in group"
              :key="f.name"
              class="factor-toggle"
              :class="{ active: selectedFactors.includes(f.name) }"
              @click="toggleFactor(f.name)"
            >
              <span class="toggle-name">{{ f.name }}</span>
              <span class="toggle-desc">{{ f.description }}</span>
            </button>
          </div>
        </div>

        <div class="mt-2" style="color: #6050a0; font-size: 0.85rem">
          已选: {{ selectedFactors.length }} 个因子
        </div>
      </CRTFrame>

      <!-- Parameters -->
      <CRTFrame title="PARAMETERS">
        <div class="param-row">
          <label>开始日期</label>
          <input v-model="startDate" type="date" class="vapor-input" />
        </div>
        <div class="param-row">
          <label>结束日期</label>
          <input v-model="endDate" type="date" class="vapor-input" />
        </div>
        <div class="param-row">
          <label>调仓周期(交易日)</label>
          <input v-model.number="rebalancePeriod" type="number" class="vapor-input" min="5" max="60" />
        </div>
        <div class="param-row">
          <label>做多分位</label>
          <input v-model.number="topPct" type="number" class="vapor-input" min="0.05" max="0.5" step="0.05" />
        </div>
        <div class="param-row">
          <label>股票池大小</label>
          <input v-model.number="poolSize" type="number" class="vapor-input" min="20" max="500" />
        </div>
        <div class="param-row">
          <label>股票池模式</label>
          <select v-model="poolMode" class="vapor-input">
            <option value="dynamic">动态</option>
            <option value="static">静态</option>
          </select>
        </div>
        <div class="param-row">
          <label>佣金率</label>
          <input v-model.number="commissionRate" type="number" class="vapor-input" min="0" max="0.01" step="0.0001" />
        </div>
        <div class="param-row">
          <label>印花税率</label>
          <input v-model.number="stampTaxRate" type="number" class="vapor-input" min="0" max="0.01" step="0.0001" />
        </div>
        <div class="param-row">
          <label>滑点率</label>
          <input v-model.number="slippageRate" type="number" class="vapor-input" min="0" max="0.01" step="0.0001" />
        </div>
        <div class="param-row">
          <label>最低成交额</label>
          <input v-model.number="minAmount" type="number" class="vapor-input" min="0" step="1000000" />
        </div>
        <div class="param-row">
          <label>最少上市天数</label>
          <input v-model.number="minListedDays" type="number" class="vapor-input" min="1" max="500" />
        </div>
        <div class="param-row">
          <label>涨跌停阈值(%)</label>
          <input v-model.number="limitPct" type="number" class="vapor-input" min="5" max="30" step="0.1" />
        </div>
        <div class="param-row">
          <label>成交口径</label>
          <select v-model="executionPrice" class="vapor-input">
            <option value="next_open">次日开盘</option>
            <option value="close">当日收盘</option>
          </select>
        </div>

        <div class="mt-4 backtest-actions">
          <button class="neon-btn primary pulse" @click="runTest" :disabled="loading">
            {{ loading ? '回测运行中...' : '运行回测' }}
          </button>
          <button v-if="canCancelTask" class="neon-btn" @click="cancelTest">
            取消任务
          </button>
        </div>

        <div v-if="loading || taskStatus" class="task-progress mt-3">
          <div class="task-progress-head">
            <span>{{ taskStatus?.stage || 'queued' }}</span>
            <strong>{{ taskProgress }}%</strong>
          </div>
          <div class="progress-shell">
            <div class="progress-fill" :style="{ width: taskProgressWidth }"></div>
          </div>
          <div class="task-message">
            {{ taskStatus?.message || '等待回测任务启动' }}
            <span v-if="taskStatus?.queue_position"> / 队列 {{ taskStatus.queue_position }}</span>
            <span v-if="taskStatus?.cache_hit"> / 缓存命中</span>
          </div>
        </div>

        <div v-if="errorMessage" class="mt-2" style="color: #ff4466; text-align: center">
          {{ errorMessage }}
        </div>
      </CRTFrame>
    </div>

    <!-- Results -->
    <div v-if="loading && !result" class="loading-glitch mt-4">RUNNING BACKTEST...</div>

    <template v-if="result">
      <!-- Metrics -->
      <div class="mt-4">
        <h3 class="section-title">组合收益指标</h3>
        <div class="mb-2" style="color: #8070b0; font-family: var(--font-terminal); font-size: 0.95rem">
          股票池来源: {{ result.config.pool_source || '--' }}
          <span v-if="result.config.data_start && result.config.data_end" style="margin-left: 1rem">
            数据区间: {{ result.config.data_start }} ~ {{ result.config.data_end }}
          </span>
          <span style="margin-left: 1rem">
            基准: {{ result.config.benchmark || 'pool_equal_weight' }}
          </span>
          <span style="margin-left: 1rem">
            股票池: {{ result.config.pool_mode === 'static' ? '静态' : '动态' }}
          </span>
          <span style="margin-left: 1rem">
            成交: {{ result.config.execution_price === 'close' ? '当日收盘' : '次日开盘' }}
          </span>
          <span v-if="result.config.factor_cache?.enabled" style="margin-left: 1rem">
            因子缓存: {{ ((result.config.factor_cache.hit_rate || 0) * 100).toFixed(1) }}%
            / 新增 {{ result.config.factor_cache.writes || 0 }}
          </span>
          <span v-if="result.config.result_cache?.enabled" style="margin-left: 1rem">
            结果缓存: {{ result.config.result_cache.hit ? '命中' : '新算' }}
          </span>
        </div>
        <div class="metric-grid">
          <div class="metric-item vapor-card">
            <div class="metric-label">总收益</div>
            <div class="metric-value" :class="result.metrics.total_return >= 0 ? 'positive' : 'negative'">
              {{ fmt(result.metrics.total_return) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">年化收益</div>
            <div class="metric-value" :class="result.metrics.annualized_return >= 0 ? 'positive' : 'negative'">
              {{ fmt(result.metrics.annualized_return) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">最大回撤</div>
            <div class="metric-value negative">
              {{ fmt(result.metrics.max_drawdown) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">基准总收益</div>
            <div class="metric-value" :class="(result.metrics.benchmark_total_return ?? 0) >= 0 ? 'positive' : 'negative'">
              {{ fmt(result.metrics.benchmark_total_return) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">超额总收益</div>
            <div class="metric-value" :class="(result.metrics.excess_total_return ?? 0) >= 0 ? 'positive' : 'negative'">
              {{ fmt(result.metrics.excess_total_return) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">夏普比率</div>
            <div class="metric-value" :class="result.metrics.sharpe_ratio >= 1 ? 'positive' : ''">
              {{ fmtNum(result.metrics.sharpe_ratio) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">信息比率</div>
            <div class="metric-value" :class="(result.metrics.information_ratio ?? 0) >= 0 ? 'positive' : 'negative'">
              {{ fmtNum(result.metrics.information_ratio) }}
            </div>
          </div>
          <div class="metric-item vapor-card">
            <div class="metric-label">调仓次数</div>
            <div class="metric-value">
              {{ result.metrics.num_periods }}
            </div>
          </div>
        </div>
      </div>

      <div class="mt-4" v-if="result.data_quality">
        <h3 class="section-title">数据质量检查</h3>
        <div class="quality-grid">
          <CRTFrame title="QUALITY SUMMARY">
            <div class="quality-status-line">
              <span>总体状态</span>
              <strong :class="`quality-pill ${result.data_quality.status}`">
                {{ qualityStatusLabel(result.data_quality.status) }}
              </strong>
            </div>
            <div class="detail-row">
              <span>行情覆盖</span>
              <span>
                {{ result.data_quality.summary.loaded_symbols }}/{{ result.data_quality.summary.requested_symbols }}
                ({{ (result.data_quality.summary.price_load_rate * 100).toFixed(1) }}%)
              </span>
            </div>
            <div class="detail-row">
              <span>池内有效样本</span>
              <span>
                {{ result.data_quality.summary.valid_pool_observations }}/{{ result.data_quality.summary.expected_pool_observations }}
                ({{ (result.data_quality.summary.pool_observation_rate * 100).toFixed(1) }}%)
              </span>
            </div>
            <div class="detail-row">
              <span>低覆盖个股</span>
              <span>{{ result.data_quality.summary.low_symbol_coverage_count }}</span>
            </div>
          </CRTFrame>

          <CRTFrame title="TIME ORDER">
            <div class="detail-row">
              <span>因子未来违规</span>
              <span>{{ result.data_quality.future_leakage.factor_future_violations }}</span>
            </div>
            <div class="detail-row">
              <span>PE未来违规</span>
              <span>{{ result.data_quality.future_leakage.pe_future_violations }}</span>
            </div>
            <div class="detail-row">
              <span>入场时间违规</span>
              <span>{{ result.data_quality.future_leakage.entry_time_violations }}</span>
            </div>
            <div class="detail-row">
              <span>调仓日前行情</span>
              <span>{{ result.data_quality.future_leakage.stale_factor_rows }}</span>
            </div>
          </CRTFrame>
        </div>

        <div class="quality-check-list">
          <div
            v-for="check in result.data_quality.checks"
            :key="check.name"
            :class="`quality-check ${check.status}`"
          >
            <div class="quality-check-head">
              <strong>{{ check.label }}</strong>
              <span>{{ qualityStatusLabel(check.status) }}</span>
            </div>
            <p>{{ check.detail }}</p>
          </div>
        </div>
      </div>

      <div class="mt-4">
        <h3 class="section-title">回测图表</h3>
        <div class="chart-grid">
          <CRTFrame title="NET VALUE">
            <div ref="netValueChartRef" class="backtest-chart"></div>
          </CRTFrame>
          <CRTFrame title="DRAWDOWN">
            <div ref="drawdownChartRef" class="backtest-chart"></div>
          </CRTFrame>
          <CRTFrame title="TURNOVER & COST">
            <div ref="costChartRef" class="backtest-chart"></div>
          </CRTFrame>
          <CRTFrame title="IC SERIES">
            <div ref="icChartRef" class="backtest-chart"></div>
          </CRTFrame>
          <CRTFrame title="QUINTILE RETURNS" class="chart-wide">
            <div v-if="researchFactorNames.length > 1" class="chart-control">
              <select v-model="selectedResearchFactor" class="vapor-input">
                <option v-for="name in researchFactorNames" :key="name" :value="name">{{ name }}</option>
              </select>
            </div>
            <div ref="quintileChartRef" class="backtest-chart compact"></div>
          </CRTFrame>
        </div>
      </div>

      <!-- IC Analysis -->
      <div class="mt-4" v-if="result.ic_analysis && Object.keys(result.ic_analysis).length > 0">
        <h3 class="section-title">因子IC分析</h3>
        <div class="grid-2">
          <CRTFrame v-for="(ic, fname) in result.ic_analysis" :key="fname" :title="fname">
            <div class="detail-row">
              <span>IC均值</span>
              <span :style="{ color: ic.ic_mean >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmtNum(ic.ic_mean) }}</span>
            </div>
            <div class="detail-row">
              <span>IC标准差</span><span>{{ fmtNum(ic.ic_std) }}</span>
            </div>
            <div class="detail-row">
              <span>ICIR</span>
              <span :style="{ color: ic.icir >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmtNum(ic.icir) }}</span>
            </div>
            <div class="detail-row">
              <span>IC>0比例</span><span>{{ fmt(ic.ic_positive_ratio) }}</span>
            </div>
          </CRTFrame>
        </div>
      </div>

      <!-- Period Returns -->
      <div class="mt-4">
        <h3 class="section-title">各调仓日收益</h3>
        <CRTFrame title="PERIOD RETURNS">
          <table class="vapor-table">
            <thead>
              <tr>
                <th>日期</th>
                <th>多头收益</th>
                <th>空头收益</th>
                <th>多空收益</th>
                <th>成本</th>
                <th>换手</th>
                <th>基准</th>
                <th>超额</th>
                <th>累计净值</th>
                <th>基准净值</th>
                <th>回撤</th>
                <th>约束</th>
                <th>持仓</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="row in result.portfolio" :key="row.date">
                <td>{{ row.date?.substring(0, 10) }}</td>
                <td :style="{ color: row.long_return >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmt(row.long_return) }}</td>
                <td :style="{ color: row.short_return >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmt(row.short_return) }}</td>
                <td :style="{ color: row.ls_return >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmt(row.ls_return) }}</td>
                <td class="negative">{{ fmt(row.cost) }}</td>
                <td>{{ fmtWeight(row.turnover) }}</td>
                <td :style="{ color: (row.benchmark_return ?? 0) >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmt(row.benchmark_return) }}</td>
                <td :style="{ color: (row.excess_return ?? 0) >= 0 ? '#ff3b3b' : '#00c853' }">{{ fmt(row.excess_return) }}</td>
                <td>{{ row.net_value?.toFixed(4) ?? '--' }}</td>
                <td>{{ row.benchmark_net_value?.toFixed(4) ?? '--' }}</td>
                <td class="negative">{{ fmt(row.drawdown) }}</td>
                <td>
                  买{{ row.n_buy_blocked ?? 0 }} / 卖{{ row.n_sell_blocked ?? 0 }}
                </td>
                <td>
                  <details class="holding-details" @toggle="toggleHoldingRow(row.date, $event)">
                    <summary>多{{ row.n_long ?? 0 }} 空{{ row.n_short ?? 0 }}</summary>
                    <div v-if="isHoldingExpanded(row.date)" class="holding-list">
                      <div v-for="h in row.long_holdings || []" :key="`L-${row.date}-${h.symbol}`" class="holding-line">
                        <span>{{ h.symbol }}</span>
                        <span>{{ fmtWeight(h.weight) }}</span>
                        <span>{{ fmt(h.forward_return) }}</span>
                        <span>{{ h.carried ? '保留' : fmtNum(h.score) }}</span>
                      </div>
                      <div v-for="h in row.short_holdings || []" :key="`S-${row.date}-${h.symbol}`" class="holding-line short">
                        <span>{{ h.symbol }}</span>
                        <span>{{ fmtWeight(h.weight) }}</span>
                        <span>{{ fmt(h.forward_return) }}</span>
                        <span>{{ h.carried ? '保留' : fmtNum(h.score) }}</span>
                      </div>
                    </div>
                  </details>
                </td>
              </tr>
            </tbody>
          </table>
        </CRTFrame>
      </div>

      <div class="mt-4" v-if="result.factor_research && Object.keys(result.factor_research).length > 0">
        <h3 class="section-title">因子研究</h3>
        <div class="grid-2">
          <CRTFrame v-for="(research, fname) in result.factor_research" :key="fname" :title="fname">
            <div class="detail-row">
              <span>观测数</span><span>{{ research.observation_count }}</span>
            </div>
            <div class="detail-row">
              <span>IC序列</span><span>{{ research.ic_series.length }} 期</span>
            </div>
            <div class="quintile-grid">
              <div v-for="(ret, idx) in research.quintile_returns" :key="`${fname}-q-${idx}`" class="quintile-cell">
                <span>Q{{ idx + 1 }}</span>
                <strong :class="ret >= 0 ? 'positive' : 'negative'">{{ fmt(ret) }}</strong>
                <small>{{ research.quintile_counts[idx] || 0 }}</small>
              </div>
            </div>
          </CRTFrame>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.factor-toggles {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.factor-toggle {
  font-family: var(--font-terminal);
  font-size: 0.95rem;
  padding: 0.5rem 0.8rem;
  background: rgba(191, 0, 255, 0.08);
  border: 1px solid #bf00ff30;
  color: #a090d0;
  cursor: pointer;
  border-radius: 3px;
  transition: all 0.3s ease;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.1rem;
}

.factor-toggle:hover {
  border-color: var(--neon-cyan);
  color: var(--neon-cyan);
}

.factor-toggle.active {
  border-color: var(--neon-cyan);
  background: rgba(0, 255, 247, 0.1);
  color: var(--neon-cyan);
  box-shadow: 0 0 10px #00fff720;
}

.toggle-name {
  font-family: var(--font-retro);
  font-size: 0.75rem;
  letter-spacing: 1px;
}

.toggle-desc {
  font-size: 0.8rem;
  opacity: 0.7;
}

.param-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1rem;
  gap: 1rem;
}

.param-row label {
  font-family: var(--font-retro);
  font-size: 0.75rem;
  color: #8070b0;
  letter-spacing: 1px;
  white-space: nowrap;
}

.param-row .vapor-input {
  flex: 1;
  max-width: 200px;
}

.backtest-actions {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 0.75rem;
  align-items: center;
}

.backtest-actions .neon-btn:first-child {
  width: 100%;
}

.task-progress {
  padding: 0.75rem;
  border: 1px solid #bf00ff35;
  background: rgba(10, 5, 30, 0.55);
  font-family: var(--font-terminal);
}

.task-progress-head {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  color: #c8b8ff;
  font-size: 0.9rem;
  margin-bottom: 0.5rem;
}

.task-progress-head span {
  color: #8070b0;
}

.progress-shell {
  height: 8px;
  overflow: hidden;
  border: 1px solid #00fff755;
  background: rgba(0, 255, 247, 0.08);
}

.progress-fill {
  height: 100%;
  width: 0;
  background: linear-gradient(90deg, #00fff7, #ff3b8d);
  transition: width 0.25s ease;
}

.task-message {
  margin-top: 0.5rem;
  color: #9f91cc;
  font-size: 0.88rem;
  line-height: 1.35;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  padding: 0.3rem 0;
  border-bottom: 1px solid #ff007f10;
  font-family: var(--font-terminal);
  font-size: 1rem;
}

.detail-row > span:first-child {
  color: #8070b0;
}

.quality-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}

.quality-status-line {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.8rem;
  font-family: var(--font-terminal);
  color: #8070b0;
}

.quality-pill {
  padding: 0.2rem 0.55rem;
  border: 1px solid #bf00ff40;
  font-size: 0.85rem;
}

.quality-pill.pass,
.quality-check.pass .quality-check-head span {
  color: var(--neon-cyan);
  border-color: #00fff760;
}

.quality-pill.warn,
.quality-check.warn .quality-check-head span {
  color: #ffd166;
  border-color: #ffd16670;
}

.quality-pill.fail,
.quality-check.fail .quality-check-head span {
  color: #ff4466;
  border-color: #ff446670;
}

.quality-check-list {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.75rem;
  margin-top: 1rem;
}

.quality-check {
  padding: 0.75rem;
  border: 1px solid #bf00ff25;
  background: rgba(10, 5, 30, 0.55);
  font-family: var(--font-terminal);
}

.quality-check.pass {
  border-color: #00fff735;
}

.quality-check.warn {
  border-color: #ffd16650;
}

.quality-check.fail {
  border-color: #ff446650;
}

.quality-check-head {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.4rem;
}

.quality-check-head strong {
  color: #d8ccff;
}

.quality-check p {
  margin: 0;
  color: #9f91cc;
  line-height: 1.45;
}

.chart-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
}

.chart-wide {
  grid-column: 1 / -1;
}

.backtest-chart {
  width: 100%;
  height: 320px;
}

.backtest-chart.compact {
  height: 280px;
}

.chart-control {
  display: flex;
  justify-content: flex-end;
  margin-bottom: 0.5rem;
}

.chart-control .vapor-input {
  width: 220px;
}

.holding-details {
  min-width: 220px;
}

.holding-details summary {
  cursor: pointer;
  color: var(--neon-cyan);
}

.holding-list {
  display: grid;
  gap: 0.25rem;
  margin-top: 0.5rem;
  max-height: 240px;
  overflow: auto;
}

.holding-line {
  display: grid;
  grid-template-columns: 4.5rem 3.5rem 4.5rem 3.5rem;
  gap: 0.4rem;
  font-size: 0.85rem;
  color: #c8b8ff;
}

.holding-line.short {
  color: #80e8d0;
}

.quintile-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 0.5rem;
  margin-top: 0.75rem;
}

.quintile-cell {
  display: grid;
  gap: 0.2rem;
  padding: 0.55rem;
  border: 1px solid #bf00ff30;
  background: rgba(191, 0, 255, 0.06);
  text-align: center;
  font-family: var(--font-terminal);
}

.quintile-cell span,
.quintile-cell small {
  color: #8070b0;
}

@media (max-width: 900px) {
  .quality-grid,
  .quality-check-list,
  .chart-grid {
    grid-template-columns: 1fr;
  }

  .backtest-actions {
    grid-template-columns: 1fr;
  }

  .backtest-chart,
  .backtest-chart.compact {
    height: 280px;
  }
}
</style>
