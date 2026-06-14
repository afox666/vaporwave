<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import {
  getScanAccuracy,
  getScanHistory,
  getScanHistoryDetail,
  getScanPeriodDetail,
  getScanPeriods,
  rebuildScanPeriods,
  triggerScan,
} from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type {
  ScanAccuracyResult,
  ScanAccuracyStock,
  ScanHistoryItem,
  ScanHistoryStock,
  ScanPeriod,
  ScanPeriodDetail,
  ScanPeriodItem,
  ScanPeriodStock,
} from '../api'

type ViewMode = 'day' | ScanPeriod

const router = useRouter()
const mode = ref<ViewMode>('day')
const dates = ref<ScanHistoryItem[]>([])
const selectedDate = ref('')
const stocks = ref<ScanHistoryStock[]>([])
const periods = ref<ScanPeriodItem[]>([])
const selectedPeriodStart = ref('')
const periodDetail = ref<ScanPeriodDetail | null>(null)
const periodStocks = ref<ScanPeriodStock[]>([])
const accuracy = ref<ScanAccuracyResult | null>(null)
const loadingDates = ref(true)
const loadingDetail = ref(false)
const loadingPeriods = ref(false)
const loadingPeriodDetail = ref(false)
const loadingAccuracy = ref(false)
const triggering = ref(false)
const rebuilding = ref(false)
let accuracyRequestId = 0

const tabs: { key: ViewMode; label: string }[] = [
  { key: 'day', label: '日' },
  { key: 'week', label: '周' },
  { key: 'month', label: '月' },
  { key: 'quarter', label: '季' },
]

const periodLabels: Record<ScanPeriod, string> = {
  week: '周榜',
  month: '月榜',
  quarter: '季榜',
}

const activePeriod = computed<ScanPeriod>(() => (mode.value === 'day' ? 'week' : mode.value))
const periodListTitle = computed(() => `${periodLabels[activePeriod.value]} PERIODS`)
const periodRankingTitle = computed(() => {
  const detail = periodDetail.value
  if (!detail) return `${periodLabels[activePeriod.value]} RANKING`
  return `${detail.period_start} ~ ${detail.period_end} ${periodLabels[activePeriod.value]}`
})
const accuracyStockBySymbol = computed(() => {
  const map = new Map<string, ScanAccuracyStock>()
  for (const stock of accuracy.value?.stocks || []) {
    map.set(stock.symbol, stock)
  }
  return map
})

async function loadDates(preferLatest = false) {
  loadingDates.value = true
  try {
    const res = await getScanHistory()
    dates.value = res.data
    const stillSelected = dates.value.some(d => d.scan_date === selectedDate.value)
    if (dates.value.length > 0 && (preferLatest || !selectedDate.value || !stillSelected)) {
      await selectDate(dates.value[0].scan_date)
    }
  } catch (e) {
    console.error(e)
  }
  loadingDates.value = false
}

async function selectDate(date: string) {
  selectedDate.value = date
  loadingDetail.value = true
  try {
    const res = await getScanHistoryDetail(date)
    stocks.value = res.data.stocks
  } catch (e) {
    console.error(e)
    stocks.value = []
  }
  loadingDetail.value = false
}

async function loadPeriods(period: ScanPeriod, preferLatest = false) {
  loadingPeriods.value = true
  try {
    const res = await getScanPeriods(period)
    periods.value = res.data
    const stillSelected = periods.value.some(p => p.period_start === selectedPeriodStart.value)
    if (periods.value.length > 0 && (preferLatest || !selectedPeriodStart.value || !stillSelected)) {
      await selectPeriod(periods.value[0].period_start)
    } else if (periods.value.length === 0) {
      selectedPeriodStart.value = ''
      periodDetail.value = null
      periodStocks.value = []
      accuracy.value = null
    }
  } catch (e) {
    console.error(e)
    periods.value = []
    periodStocks.value = []
    accuracy.value = null
  }
  loadingPeriods.value = false
}

async function loadAccuracy(periodStart: string) {
  if (mode.value !== 'week') {
    accuracyRequestId += 1
    accuracy.value = null
    loadingAccuracy.value = false
    return
  }
  const requestId = ++accuracyRequestId
  loadingAccuracy.value = true
  try {
    const res = await getScanAccuracy({
      period: 'week',
      period_start: periodStart,
      top_n: 20,
      bucket_count: 5,
    })
    if (mode.value === 'week' && selectedPeriodStart.value === periodStart) {
      accuracy.value = res.data
    }
  } catch (e) {
    console.error(e)
    if (selectedPeriodStart.value === periodStart) {
      accuracy.value = null
    }
  }
  if (requestId === accuracyRequestId) {
    loadingAccuracy.value = false
  }
}

async function selectPeriod(periodStart: string) {
  selectedPeriodStart.value = periodStart
  loadingPeriodDetail.value = true
  accuracy.value = null
  try {
    const res = await getScanPeriodDetail(activePeriod.value, periodStart)
    periodDetail.value = res.data
    periodStocks.value = res.data.stocks
    await loadAccuracy(periodStart)
  } catch (e) {
    console.error(e)
    periodDetail.value = null
    periodStocks.value = []
    accuracy.value = null
  }
  loadingPeriodDetail.value = false
}

async function switchMode(next: ViewMode) {
  mode.value = next
  if (next === 'day') {
    accuracyRequestId += 1
    accuracy.value = null
    loadingAccuracy.value = false
    if (dates.value.length === 0) await loadDates()
    return
  }
  selectedPeriodStart.value = ''
  periodDetail.value = null
  periodStocks.value = []
  accuracyRequestId += 1
  accuracy.value = null
  loadingAccuracy.value = false
  await loadPeriods(next, true)
}

async function doTriggerScan() {
  triggering.value = true
  try {
    await triggerScan(100)
    if (mode.value === 'day') {
      await loadDates(true)
    } else {
      await loadPeriods(activePeriod.value, true)
    }
  } catch (e) {
    console.error(e)
  }
  triggering.value = false
}

async function doRebuildPeriods() {
  rebuilding.value = true
  try {
    await rebuildScanPeriods(activePeriod.value, 100)
    await loadPeriods(activePeriod.value, true)
  } catch (e) {
    console.error(e)
  }
  rebuilding.value = false
}

function isPeriodStock(stock: ScanHistoryStock | ScanPeriodStock): stock is ScanPeriodStock {
  return 'period_score' in stock
}

function stockQuery(stock: ScanHistoryStock | ScanPeriodStock) {
  const price = isPeriodStock(stock) ? stock.latest_price : stock.price
  const score = isPeriodStock(stock) ? stock.period_score : stock.score
  return {
    name: stock.name || undefined,
    price: price != null && Number.isFinite(price) ? String(price) : undefined,
    score: score != null && Number.isFinite(score) ? String(score) : undefined,
  }
}

function goToStock(stock: ScanHistoryStock | ScanPeriodStock | string) {
  if (typeof stock === 'string') {
    router.push(`/stock/${stock}`)
    return
  }
  router.push({
    path: `/stock/${stock.symbol}`,
    query: stockQuery(stock),
  })
}

function fmt(value: number | null | undefined, digits = 2) {
  return value != null && Number.isFinite(value) ? value.toFixed(digits) : '--'
}

function fmtSigned(value: number | null | undefined, digits = 2, suffix = '') {
  if (value == null || !Number.isFinite(value)) return '--'
  return `${value >= 0 ? '+' : ''}${value.toFixed(digits)}${suffix}`
}

function fmtRate(value: number | null | undefined, digits = 1) {
  if (value == null || !Number.isFinite(value)) return '--'
  return `${(value * 100).toFixed(digits)}%`
}

function periodRange(item: ScanPeriodItem) {
  return `${item.period_start} ~ ${item.period_end}`
}

function accuracyFor(stock: ScanPeriodStock) {
  return accuracyStockBySymbol.value.get(stock.symbol)
}

function rankDeltaClass(value: number | null | undefined) {
  if (value == null || !Number.isFinite(value)) return ''
  return value <= 0 ? 'positive' : 'negative'
}

onMounted(() => {
  loadDates()
})
</script>

<template>
  <div class="container">
    <div class="flex-between mb-3 header-row">
      <div>
        <h2 class="section-title" style="margin-bottom: 0">&#x1F4C5; 扫描历史</h2>
        <div class="history-tabs">
          <button
            v-for="tab in tabs"
            :key="tab.key"
            class="tab-btn"
            :class="{ active: mode === tab.key }"
            @click="switchMode(tab.key)"
          >
            {{ tab.label }}
          </button>
        </div>
      </div>
      <div class="period-actions">
        <button v-if="mode !== 'day'" class="neon-btn" @click="doRebuildPeriods" :disabled="rebuilding">
          {{ rebuilding ? '重建中...' : '重建周期榜' }}
        </button>
        <button class="neon-btn" @click="doTriggerScan" :disabled="triggering">
          {{ triggering ? '扫描中...' : '手动触发扫描' }}
        </button>
      </div>
    </div>

    <template v-if="mode === 'day'">
      <div v-if="loadingDates" class="loading-glitch">LOADING HISTORY...</div>

      <template v-else-if="dates.length === 0">
        <div class="vapor-card empty-state">
          <div class="empty-title">暂无扫描记录</div>
          <div class="empty-subtitle">点击「手动触发扫描」或等待每天 16:00 自动扫描</div>
        </div>
      </template>

      <template v-else>
        <div class="scan-history-layout">
          <div class="date-list">
            <CRTFrame title="SCAN DATES">
              <div
                v-for="d in dates"
                :key="d.scan_date"
                class="date-item"
                :class="{ active: d.scan_date === selectedDate }"
                @click="selectDate(d.scan_date)"
              >
                <span class="date-label">{{ d.scan_date }}</span>
                <span class="date-count">{{ d.total_stocks }} 只</span>
              </div>
            </CRTFrame>
          </div>

          <div class="detail-panel">
            <div v-if="loadingDetail" class="loading-glitch">LOADING SCAN DATA...</div>

            <template v-else-if="stocks.length > 0">
              <div v-if="stocks.length >= 3" class="grid-3 mb-3">
                <div
                  v-for="stock in stocks.slice(0, 3)"
                  :key="stock.symbol"
                  class="stock-hero-card"
                  @click="goToStock(stock)"
                >
                  <span class="rank">#{{ stock.rank }}</span>
                  <div class="name">{{ stock.name }}</div>
                  <div class="symbol">{{ stock.symbol }}</div>
                  <div class="price mt-2">¥{{ fmt(stock.price) }}</div>
                  <div
                    class="change"
                    :class="(stock.change_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                    style="font-family: var(--font-terminal); font-size: 1.2rem"
                  >
                    {{ fmtSigned(stock.change_pct, 2, '%') }}
                  </div>
                  <div class="mt-2">
                    <span class="neon-tag cyan">评分: {{ fmt(stock.score, 0) }}</span>
                    <span class="neon-tag purple" style="margin-left: 0.5rem">{{ stock.industry }}</span>
                  </div>
                </div>
              </div>

              <CRTFrame :title="`${selectedDate} RANKING`">
                <div class="table-scroll">
                  <table class="vapor-table">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>代码</th>
                        <th>名称</th>
                        <th>价格</th>
                        <th>涨跌幅</th>
                        <th>评分</th>
                        <th>行业</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="stock in stocks"
                        :key="stock.symbol"
                        @click="goToStock(stock)"
                        style="cursor: pointer"
                      >
                        <td>{{ stock.rank }}</td>
                        <td style="color: var(--neon-cyan)">{{ stock.symbol }}</td>
                        <td style="color: #fff">{{ stock.name }}</td>
                        <td style="color: var(--hot-yellow)">¥{{ fmt(stock.price) }}</td>
                        <td
                          :class="(stock.change_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                          style="font-family: var(--font-terminal)"
                        >
                          {{ fmtSigned(stock.change_pct, 2, '%') }}
                        </td>
                        <td>
                          <span
                            class="neon-tag"
                            :style="{
                              color: (stock.score ?? 0) >= 80 ? '#ff3b3b' : (stock.score ?? 0) >= 60 ? '#ffd700' : '#00c853',
                              borderColor: (stock.score ?? 0) >= 80 ? '#ff3b3b' : (stock.score ?? 0) >= 60 ? '#ffd700' : '#00c853',
                            }"
                          >
                            {{ fmt(stock.score, 0) }}
                          </span>
                        </td>
                        <td style="color: #8070b0">{{ stock.industry }}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </CRTFrame>
            </template>

            <div v-else class="vapor-card empty-state">选择左侧日期查看扫描结果</div>
          </div>
        </div>
      </template>
    </template>

    <template v-else>
      <div v-if="loadingPeriods" class="loading-glitch">LOADING PERIOD RANKINGS...</div>

      <template v-else-if="periods.length === 0">
        <div class="vapor-card empty-state">
          <div class="empty-title">暂无{{ periodLabels[activePeriod] }}</div>
          <div class="empty-subtitle">先积累日扫描记录，或点击「重建周期榜」从历史日榜生成</div>
        </div>
      </template>

      <template v-else>
        <div class="scan-history-layout">
          <div class="date-list">
            <CRTFrame :title="periodListTitle">
              <div
                v-for="p in periods"
                :key="p.period_start"
                class="date-item period-item"
                :class="{ active: p.period_start === selectedPeriodStart }"
                @click="selectPeriod(p.period_start)"
              >
                <span>
                  <span class="date-label">{{ p.period_start }}</span>
                  <span v-if="p.is_current" class="current-flag">当前</span>
                </span>
                <span class="date-count">{{ p.scan_days }} 天</span>
              </div>
            </CRTFrame>
          </div>

          <div class="detail-panel">
            <div v-if="loadingPeriodDetail" class="loading-glitch">LOADING PERIOD DATA...</div>

            <template v-else-if="periodStocks.length > 0">
              <div v-if="periodDetail" class="period-meta mb-3">
                <span>{{ periodRange(periodDetail) }}</span>
                <span>日榜 {{ periodDetail.scan_days }} 天</span>
                <span>候选 {{ periodDetail.candidate_count }} 只</span>
                <span>数据 {{ periodDetail.data_start }} ~ {{ periodDetail.data_end }}</span>
              </div>

              <CRTFrame v-if="activePeriod === 'week' && (loadingAccuracy || accuracy)" title="WEEKLY ACCURACY" class="mb-3">
                <div v-if="loadingAccuracy" class="loading-glitch accuracy-loading">LOADING ACCURACY...</div>
                <template v-else-if="accuracy">
                  <div class="accuracy-meta">
                    <span>{{ accuracy.summary.entry_date }} → {{ accuracy.summary.as_of }}</span>
                    <span>有效 {{ accuracy.summary.evaluated_count }} / {{ accuracy.summary.ranked_count }}</span>
                    <span>缺失 {{ accuracy.summary.missing_count }}</span>
                    <span>{{ accuracy.summary.price_source }}</span>
                  </div>

                  <div class="accuracy-metrics">
                    <div class="accuracy-metric">
                      <span>准确度</span>
                      <strong>{{ fmt(accuracy.metrics.accuracy_score, 1) }}</strong>
                    </div>
                    <div class="accuracy-metric">
                      <span>Rank IC</span>
                      <strong>{{ fmt(accuracy.metrics.rank_ic, 3) }}</strong>
                    </div>
                    <div class="accuracy-metric">
                      <span>Top20 超额</span>
                      <strong :class="(accuracy.metrics.top_excess_return_pct ?? 0) >= 0 ? 'positive' : 'negative'">
                        {{ fmtSigned(accuracy.metrics.top_excess_return_pct, 2, '%') }}
                      </strong>
                    </div>
                    <div class="accuracy-metric">
                      <span>Top20 正收益</span>
                      <strong>{{ fmtRate(accuracy.metrics.top_positive_rate, 1) }}</strong>
                    </div>
                    <div class="accuracy-metric">
                      <span>Top20 跑赢</span>
                      <strong>{{ fmtRate(accuracy.metrics.top_outperform_rate, 1) }}</strong>
                    </div>
                    <div class="accuracy-metric">
                      <span>分层单调</span>
                      <strong>{{ fmt(accuracy.metrics.monotonicity_score, 1) }}</strong>
                    </div>
                  </div>

                  <div class="accuracy-subgrid">
                    <div>
                      <div class="accuracy-subtitle">分层收益</div>
                      <div class="table-scroll">
                        <table class="vapor-table compact-table">
                          <thead>
                            <tr>
                              <th>组</th>
                              <th>排名</th>
                              <th>样本</th>
                              <th>均涨幅</th>
                              <th>正收益</th>
                            </tr>
                          </thead>
                          <tbody>
                            <tr v-for="bucket in accuracy.buckets" :key="bucket.bucket">
                              <td>Q{{ bucket.bucket }}</td>
                              <td>{{ bucket.rank_start }}-{{ bucket.rank_end }}</td>
                              <td>{{ bucket.sample_count }}</td>
                              <td :class="(bucket.avg_return_pct ?? 0) >= 0 ? 'positive' : 'negative'">
                                {{ fmtSigned(bucket.avg_return_pct, 2, '%') }}
                              </td>
                              <td>{{ fmtRate(bucket.positive_rate, 1) }}</td>
                            </tr>
                          </tbody>
                        </table>
                      </div>
                    </div>

                    <div>
                      <div class="accuracy-subtitle">权重诊断</div>
                      <div class="table-scroll">
                        <table class="vapor-table compact-table">
                          <thead>
                            <tr>
                              <th>组件</th>
                              <th>权重</th>
                              <th>相关</th>
                              <th>建议</th>
                            </tr>
                          </thead>
                          <tbody>
                            <tr v-for="component in accuracy.components" :key="component.key">
                              <td>{{ component.label }}</td>
                              <td>{{ fmt(component.weight, 0) }}</td>
                              <td :class="(component.correlation ?? 0) >= 0 ? 'positive' : 'negative'">
                                {{ fmt(component.correlation, 3) }}
                              </td>
                              <td>{{ component.suggestion }}</td>
                            </tr>
                          </tbody>
                        </table>
                      </div>
                    </div>
                  </div>
                </template>
              </CRTFrame>

              <div v-if="periodStocks.length >= 3" class="grid-3 mb-3">
                <div
                  v-for="stock in periodStocks.slice(0, 3)"
                  :key="stock.symbol"
                  class="stock-hero-card"
                  @click="goToStock(stock)"
                >
                  <span class="rank">#{{ stock.rank }}</span>
                  <div class="name">{{ stock.name }}</div>
                  <div class="symbol">{{ stock.symbol }}</div>
                  <div class="price mt-2">周期分 {{ fmt(stock.period_score, 1) }}</div>
                  <div
                    class="change"
                    :class="(stock.return_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                    style="font-family: var(--font-terminal); font-size: 1.2rem"
                  >
                    {{ fmtSigned(stock.return_pct, 2, '%') }}
                  </div>
                  <div class="mt-2 metric-row">
                    <span class="neon-tag cyan">上榜 {{ stock.appearances }} 天</span>
                    <span class="neon-tag purple">{{ stock.industry }}</span>
                  </div>
                </div>
              </div>

              <CRTFrame :title="periodRankingTitle">
                <div class="table-scroll">
                  <table class="vapor-table">
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>代码</th>
                        <th>名称</th>
                        <th>周期分</th>
                        <th>上榜</th>
                        <th>均排</th>
                        <th>区间涨幅</th>
                        <th v-if="activePeriod === 'week'">验证涨幅</th>
                        <th v-if="activePeriod === 'week'">实际排名</th>
                        <th v-if="activePeriod === 'week'">排名偏差</th>
                        <th>评分变化</th>
                        <th>行业</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        v-for="stock in periodStocks"
                        :key="stock.symbol"
                        @click="goToStock(stock)"
                        style="cursor: pointer"
                      >
                        <td>{{ stock.rank }}</td>
                        <td style="color: var(--neon-cyan)">{{ stock.symbol }}</td>
                        <td style="color: #fff">{{ stock.name }}</td>
                        <td>
                          <span class="neon-tag cyan">{{ fmt(stock.period_score, 1) }}</span>
                        </td>
                        <td>{{ stock.appearances }} 天</td>
                        <td>{{ fmt(stock.avg_rank, 1) }}</td>
                        <td :class="(stock.return_pct ?? 0) >= 0 ? 'positive' : 'negative'">
                          {{ fmtSigned(stock.return_pct, 2, '%') }}
                        </td>
                        <td
                          v-if="activePeriod === 'week'"
                          :class="(accuracyFor(stock)?.validation_return_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                        >
                          {{ fmtSigned(accuracyFor(stock)?.validation_return_pct, 2, '%') }}
                        </td>
                        <td v-if="activePeriod === 'week'">
                          {{ fmt(accuracyFor(stock)?.actual_rank, 0) }}
                        </td>
                        <td v-if="activePeriod === 'week'" :class="rankDeltaClass(accuracyFor(stock)?.rank_delta)">
                          {{ fmtSigned(accuracyFor(stock)?.rank_delta, 0) }}
                        </td>
                        <td :class="(stock.score_delta ?? 0) >= 0 ? 'positive' : 'negative'">
                          {{ fmtSigned(stock.score_delta, 1) }}
                        </td>
                        <td style="color: #8070b0">{{ stock.industry }}</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </CRTFrame>
            </template>

            <div v-else class="vapor-card empty-state">选择左侧周期查看二次评价结果</div>
          </div>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.positive { color: #ff3b3b; }
.negative { color: #00c853; }
.change { text-shadow: 0 0 5px currentColor; }

.header-row {
  align-items: flex-start;
  gap: 1rem;
}

.history-tabs {
  display: flex;
  gap: 0.4rem;
  margin-top: 0.8rem;
}

.tab-btn {
  min-width: 42px;
  height: 34px;
  border: 1px solid #00fff740;
  background: rgba(0, 255, 247, 0.04);
  color: #8070b0;
  font-family: var(--font-retro);
  cursor: pointer;
  transition: all 0.2s ease;
}

.tab-btn.active,
.tab-btn:hover {
  color: var(--neon-cyan);
  border-color: var(--neon-cyan);
  box-shadow: 0 0 12px rgba(0, 255, 247, 0.18);
}

.period-actions {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
  justify-content: flex-end;
}

.scan-history-layout {
  display: grid;
  grid-template-columns: 220px 1fr;
  gap: 1.5rem;
  align-items: start;
}

.date-list {
  position: sticky;
  top: 1rem;
}

.date-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.75rem;
  padding: 0.6rem 0.8rem;
  cursor: pointer;
  border-bottom: 1px solid #ff007f10;
  transition: all 0.2s ease;
  font-family: var(--font-terminal);
}

.date-item:hover {
  background: rgba(0, 255, 247, 0.05);
}

.date-item.active {
  background: rgba(191, 0, 255, 0.1);
  border-left: 3px solid var(--neon-cyan);
}

.date-label {
  color: var(--neon-cyan);
  font-size: 1rem;
}

.date-count {
  color: #8070b0;
  font-size: 0.85rem;
  white-space: nowrap;
}

.current-flag {
  display: inline-block;
  margin-left: 0.4rem;
  color: #ffd700;
  font-size: 0.72rem;
}

.period-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  color: #8070b0;
  font-family: var(--font-terminal);
  font-size: 0.88rem;
}

.period-meta span {
  border: 1px solid #bf00ff30;
  padding: 0.35rem 0.55rem;
  background: rgba(191, 0, 255, 0.05);
}

.metric-row {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.table-scroll {
  overflow-x: auto;
}

.accuracy-loading {
  padding: 0.75rem 0;
}

.accuracy-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.55rem;
  margin-bottom: 0.9rem;
  color: #8070b0;
  font-family: var(--font-terminal);
  font-size: 0.84rem;
}

.accuracy-meta span {
  border: 1px solid #00fff730;
  background: rgba(0, 255, 247, 0.04);
  padding: 0.3rem 0.5rem;
}

.accuracy-metrics {
  display: grid;
  grid-template-columns: repeat(6, minmax(94px, 1fr));
  gap: 0.65rem;
  margin-bottom: 1rem;
}

.accuracy-metric {
  min-height: 64px;
  border: 1px solid #bf00ff30;
  background: rgba(191, 0, 255, 0.05);
  padding: 0.55rem 0.65rem;
}

.accuracy-metric span {
  display: block;
  color: #8070b0;
  font-family: var(--font-terminal);
  font-size: 0.78rem;
  margin-bottom: 0.35rem;
}

.accuracy-metric strong {
  color: var(--neon-cyan);
  font-family: var(--font-retro);
  font-size: 1.15rem;
  font-weight: 400;
}

.accuracy-subgrid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr);
  gap: 1rem;
}

.accuracy-subtitle {
  color: var(--neon-cyan);
  font-family: var(--font-retro);
  font-size: 0.86rem;
  margin-bottom: 0.55rem;
}

.compact-table th,
.compact-table td {
  padding: 0.42rem 0.5rem;
  white-space: nowrap;
}

.empty-state {
  text-align: center;
  padding: 2rem;
  color: #6050a0;
}

.empty-title {
  font-family: var(--font-retro);
  color: #8070b0;
  font-size: 0.9rem;
  letter-spacing: 1px;
}

.empty-subtitle {
  color: #6050a0;
  font-size: 0.85rem;
  margin-top: 0.5rem;
}

@media (max-width: 768px) {
  .scan-history-layout {
    grid-template-columns: 1fr;
  }

  .date-list {
    position: static;
  }

  .period-actions {
    justify-content: flex-start;
  }

  .accuracy-metrics,
  .accuracy-subgrid {
    grid-template-columns: 1fr;
  }
}
</style>
