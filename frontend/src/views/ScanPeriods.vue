<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { getScanPeriodDetail, getScanPeriods, rebuildScanPeriods } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type { ScanPeriod, ScanPeriodDetail, ScanPeriodItem, ScanPeriodStock } from '../api'

const router = useRouter()
const activePeriod = ref<ScanPeriod>('week')
const periods = ref<ScanPeriodItem[]>([])
const selectedStart = ref('')
const detail = ref<ScanPeriodDetail | null>(null)
const stocks = ref<ScanPeriodStock[]>([])
const loadingList = ref(true)
const loadingDetail = ref(false)
const rebuilding = ref(false)
const expandedScoreSymbol = ref<string | null>(null)

const periodTabs: { key: ScanPeriod; label: string }[] = [
  { key: 'week', label: '周' },
  { key: 'month', label: '月' },
  { key: 'quarter', label: '季' },
]

const periodNames: Record<ScanPeriod, string> = {
  week: '周榜',
  month: '月榜',
  quarter: '季榜',
}

type ScoreBreakdownItem = {
  key: string
  label: string
  raw: number
  points: number
  maxPoints: number
  meta: string
}

const listTitle = computed(() => `${periodNames[activePeriod.value]} PERIODS`)
const rankingTitle = computed(() => {
  if (!detail.value) return `${periodNames[activePeriod.value]} RANKING`
  return `${detail.value.period_start} ~ ${detail.value.period_end} ${periodNames[activePeriod.value]}`
})

async function loadPeriods(preferLatest = false) {
  loadingList.value = true
  try {
    const res = await getScanPeriods(activePeriod.value)
    periods.value = res.data
    const stillSelected = periods.value.some(item => item.period_start === selectedStart.value)
    if (periods.value.length > 0 && (preferLatest || !selectedStart.value || !stillSelected)) {
      await selectPeriod(periods.value[0].period_start)
    } else if (periods.value.length === 0) {
      selectedStart.value = ''
      detail.value = null
      stocks.value = []
      expandedScoreSymbol.value = null
    }
  } catch (e) {
    console.error(e)
    periods.value = []
    detail.value = null
    stocks.value = []
    expandedScoreSymbol.value = null
  }
  loadingList.value = false
}

async function selectPeriod(periodStart: string) {
  selectedStart.value = periodStart
  loadingDetail.value = true
  try {
    const res = await getScanPeriodDetail(activePeriod.value, periodStart)
    detail.value = res.data
    stocks.value = res.data.stocks
    expandedScoreSymbol.value = null
  } catch (e) {
    console.error(e)
    detail.value = null
    stocks.value = []
    expandedScoreSymbol.value = null
  }
  loadingDetail.value = false
}

async function switchPeriod(period: ScanPeriod) {
  activePeriod.value = period
  selectedStart.value = ''
  detail.value = null
  stocks.value = []
  expandedScoreSymbol.value = null
  await loadPeriods(true)
}

async function rebuildCurrentPeriod() {
  rebuilding.value = true
  try {
    await rebuildScanPeriods(activePeriod.value, 100)
    await loadPeriods(true)
  } catch (e) {
    console.error(e)
  }
  rebuilding.value = false
}

function goToStock(stock: ScanPeriodStock) {
  router.push({
    path: `/stock/${stock.symbol}`,
    query: {
      name: stock.name || undefined,
      price: stock.latest_price != null && Number.isFinite(stock.latest_price) ? String(stock.latest_price) : undefined,
      score: Number.isFinite(stock.period_score) ? String(stock.period_score) : undefined,
    },
  })
}

function fmt(value: number | null | undefined, digits = 2) {
  return value != null && Number.isFinite(value) ? value.toFixed(digits) : '--'
}

function fmtSigned(value: number | null | undefined, digits = 2, suffix = '') {
  if (value == null || !Number.isFinite(value)) return '--'
  return `${value >= 0 ? '+' : ''}${value.toFixed(digits)}${suffix}`
}

function clamp(value: number, min = 0, max = 100) {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, value))
}

function toggleScoreBreakdown(symbol: string) {
  expandedScoreSymbol.value = expandedScoreSymbol.value === symbol ? null : symbol
}

function scoreBreakdown(stock: ScanPeriodStock): ScoreBreakdownItem[] {
  const scanDays = Math.max(detail.value?.scan_days ?? 0, 1)
  const appearanceRaw = clamp((stock.appearances / scanDays) * 100)
  const appearancePoints = appearanceRaw * 0.3
  const dailyRaw = clamp(stock.avg_daily_score ?? 0)
  const dailyPoints = dailyRaw * 0.2
  const returnRaw = clamp((((stock.return_pct ?? 0) + 10) / 30) * 100)
  const returnPoints = returnRaw * 0.15
  const deltaRaw = clamp((((stock.score_delta ?? 0) + 20) / 40) * 100)
  const deltaPoints = deltaRaw * 0.1
  const rankPoints = clamp(
    stock.period_score - appearancePoints - dailyPoints - returnPoints - deltaPoints,
    0,
    25,
  )
  const rankRaw = rankPoints / 0.25

  return [
    {
      key: 'appearance',
      label: '上榜稳定',
      raw: appearanceRaw,
      points: appearancePoints,
      maxPoints: 30,
      meta: `${stock.appearances}/${scanDays} 天`,
    },
    {
      key: 'rank',
      label: '排名强度',
      raw: rankRaw,
      points: rankPoints,
      maxPoints: 25,
      meta: `均排 #${fmt(stock.avg_rank, 1)}`,
    },
    {
      key: 'daily',
      label: '日评分均值',
      raw: dailyRaw,
      points: dailyPoints,
      maxPoints: 20,
      meta: `均值 ${fmt(stock.avg_daily_score, 1)}`,
    },
    {
      key: 'return',
      label: '区间收益',
      raw: returnRaw,
      points: returnPoints,
      maxPoints: 15,
      meta: fmtSigned(stock.return_pct, 2, '%'),
    },
    {
      key: 'delta',
      label: '评分变化',
      raw: deltaRaw,
      points: deltaPoints,
      maxPoints: 10,
      meta: fmtSigned(stock.score_delta, 1),
    },
  ]
}

function scoreBreakdownTotal(stock: ScanPeriodStock) {
  return scoreBreakdown(stock).reduce((sum, item) => sum + item.points, 0)
}

function scoreBreakdownWidth(item: ScoreBreakdownItem) {
  return `${clamp((item.points / item.maxPoints) * 100)}%`
}

onMounted(() => {
  loadPeriods()
})
</script>

<template>
  <div class="container">
    <div class="flex-between mb-3 header-row">
      <div>
        <h2 class="section-title" style="margin-bottom: 0">周期扫描排行榜</h2>
        <div class="period-tabs">
          <button
            v-for="tab in periodTabs"
            :key="tab.key"
            class="tab-btn"
            :class="{ active: activePeriod === tab.key }"
            @click="switchPeriod(tab.key)"
          >
            {{ tab.label }}
          </button>
        </div>
      </div>
      <div class="actions">
        <button class="neon-btn" @click="loadPeriods(true)" :disabled="loadingList">刷新</button>
        <button class="neon-btn" @click="rebuildCurrentPeriod" :disabled="rebuilding">
          {{ rebuilding ? '重建中...' : '重建周期榜' }}
        </button>
      </div>
    </div>

    <div v-if="loadingList" class="loading-glitch">LOADING PERIODS...</div>

    <template v-else-if="periods.length === 0">
      <div class="vapor-card empty-state">
        <div class="empty-title">暂无{{ periodNames[activePeriod] }}</div>
        <div class="empty-subtitle">先运行日扫描，或点击「重建周期榜」从扫描历史生成</div>
      </div>
    </template>

    <template v-else>
      <div class="period-layout">
        <aside class="period-list">
          <CRTFrame :title="listTitle">
            <div
              v-for="item in periods"
              :key="item.period_start"
              class="period-item"
              :class="{ active: item.period_start === selectedStart }"
              @click="selectPeriod(item.period_start)"
            >
              <div>
                <span class="period-start">{{ item.period_start }}</span>
                <span v-if="item.is_current" class="current-flag">当前</span>
              </div>
              <div class="period-sub">
                <span>{{ item.scan_days }} 天</span>
                <span>{{ item.candidate_count }} 只</span>
              </div>
            </div>
          </CRTFrame>
        </aside>

        <section class="period-detail">
          <div v-if="loadingDetail" class="loading-glitch">LOADING RANKING...</div>

          <template v-else-if="detail && stocks.length > 0">
            <div class="period-meta mb-3">
              <span>{{ detail.period_start }} ~ {{ detail.period_end }}</span>
              <span>日榜 {{ detail.scan_days }} 天</span>
              <span>候选 {{ detail.candidate_count }} 只</span>
              <span>数据 {{ detail.data_start }} ~ {{ detail.data_end }}</span>
            </div>

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
                <div class="price mt-2">周期分 {{ fmt(stock.period_score, 1) }}</div>
                <div
                  class="change"
                  :class="(stock.return_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                  style="font-family: var(--font-terminal); font-size: 1.2rem"
                >
                  {{ fmtSigned(stock.return_pct, 2, '%') }}
                </div>
                <div class="mt-2 hero-tags">
                  <span class="neon-tag cyan">上榜 {{ stock.appearances }} 天</span>
                  <span class="neon-tag purple">{{ stock.industry || 'N/A' }}</span>
                </div>
              </div>
            </div>

            <CRTFrame :title="rankingTitle">
              <div class="table-scroll">
                <table class="vapor-table">
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>代码</th>
                      <th>名称</th>
                      <th>周期分</th>
                      <th>拆解</th>
                      <th>上榜</th>
                      <th>最佳</th>
                      <th>均排</th>
                      <th>区间涨幅</th>
                      <th>评分变化</th>
                      <th>行业</th>
                    </tr>
                  </thead>
                  <tbody>
                    <template v-for="stock in stocks" :key="stock.symbol">
                      <tr @click="goToStock(stock)" style="cursor: pointer">
                        <td>{{ stock.rank }}</td>
                        <td style="color: var(--neon-cyan)">{{ stock.symbol }}</td>
                        <td style="color: #fff">{{ stock.name }}</td>
                        <td><span class="neon-tag cyan">{{ fmt(stock.period_score, 1) }}</span></td>
                        <td>
                          <button
                            class="score-toggle"
                            :class="{ active: expandedScoreSymbol === stock.symbol }"
                            @click.stop="toggleScoreBreakdown(stock.symbol)"
                          >
                            {{ expandedScoreSymbol === stock.symbol ? '收起' : '拆解' }}
                          </button>
                        </td>
                        <td>{{ stock.appearances }} 天</td>
                        <td>#{{ stock.best_rank }}</td>
                        <td>{{ fmt(stock.avg_rank, 1) }}</td>
                        <td :class="(stock.return_pct ?? 0) >= 0 ? 'positive' : 'negative'">
                          {{ fmtSigned(stock.return_pct, 2, '%') }}
                        </td>
                        <td :class="(stock.score_delta ?? 0) >= 0 ? 'positive' : 'negative'">
                          {{ fmtSigned(stock.score_delta, 1) }}
                        </td>
                        <td style="color: #8070b0">{{ stock.industry || 'N/A' }}</td>
                      </tr>
                      <tr v-if="expandedScoreSymbol === stock.symbol" class="score-breakdown-row">
                        <td colspan="11">
                          <div class="score-breakdown-panel" @click.stop>
                            <div class="score-breakdown-title">
                              <span>评分拆解</span>
                              <strong>{{ fmt(scoreBreakdownTotal(stock), 1) }}</strong>
                            </div>
                            <div class="score-breakdown-grid">
                              <div
                                v-for="item in scoreBreakdown(stock)"
                                :key="item.key"
                                class="score-part"
                              >
                                <div class="score-part-head">
                                  <span>{{ item.label }}</span>
                                  <strong>{{ fmt(item.points, 1) }}/{{ item.maxPoints }}</strong>
                                </div>
                                <div class="score-bar">
                                  <span :style="{ width: scoreBreakdownWidth(item) }"></span>
                                </div>
                                <div class="score-part-meta">
                                  <span>{{ item.meta }}</span>
                                  <span>{{ fmt(item.raw, 1) }} 分</span>
                                </div>
                              </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    </template>
                  </tbody>
                </table>
              </div>
            </CRTFrame>
          </template>

          <div v-else class="vapor-card empty-state">选择左侧周期查看排行榜</div>
        </section>
      </div>
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

.period-tabs,
.actions {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.period-tabs {
  margin-top: 0.8rem;
}

.actions {
  justify-content: flex-end;
}

.tab-btn {
  min-width: 44px;
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

.period-layout {
  display: grid;
  grid-template-columns: 240px 1fr;
  gap: 1.5rem;
  align-items: start;
}

.period-list {
  position: sticky;
  top: 1rem;
}

.period-item {
  padding: 0.75rem 0.8rem;
  cursor: pointer;
  border-bottom: 1px solid #ff007f10;
  transition: all 0.2s ease;
  font-family: var(--font-terminal);
}

.period-item:hover {
  background: rgba(0, 255, 247, 0.05);
}

.period-item.active {
  background: rgba(191, 0, 255, 0.1);
  border-left: 3px solid var(--neon-cyan);
}

.period-start {
  color: var(--neon-cyan);
  font-size: 1rem;
}

.period-sub {
  display: flex;
  justify-content: space-between;
  color: #8070b0;
  font-size: 0.82rem;
  margin-top: 0.35rem;
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

.hero-tags {
  display: flex;
  gap: 0.5rem;
  flex-wrap: wrap;
}

.table-scroll {
  overflow-x: auto;
}

.vapor-table {
  min-width: 980px;
}

.vapor-table th,
.vapor-table td {
  white-space: nowrap;
}

.score-toggle {
  min-width: 48px;
  height: 28px;
  border: 1px solid #bf00ff55;
  background: rgba(191, 0, 255, 0.08);
  color: #bca8ff;
  font-family: var(--font-terminal);
  font-size: 0.78rem;
  cursor: pointer;
  transition: all 0.2s ease;
}

.score-toggle:hover,
.score-toggle.active {
  color: var(--neon-cyan);
  border-color: var(--neon-cyan);
  box-shadow: 0 0 10px rgba(0, 255, 247, 0.18);
}

.score-breakdown-row td {
  padding: 0;
  background: rgba(5, 2, 18, 0.72);
  white-space: normal;
}

.score-breakdown-panel {
  padding: 0.85rem;
  border-top: 1px solid #00fff722;
  border-bottom: 1px solid #bf00ff22;
}

.score-breakdown-title {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1rem;
  margin-bottom: 0.7rem;
  color: var(--neon-cyan);
  font-family: var(--font-retro);
  font-size: 0.82rem;
  letter-spacing: 1px;
}

.score-breakdown-title strong {
  color: #fff;
  font-family: var(--font-terminal);
  font-size: 1rem;
  letter-spacing: 0;
}

.score-breakdown-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(132px, 1fr));
  gap: 0.7rem;
}

.score-part {
  border: 1px solid #bf00ff30;
  background: rgba(191, 0, 255, 0.05);
  padding: 0.65rem;
}

.score-part-head,
.score-part-meta {
  display: flex;
  justify-content: space-between;
  gap: 0.6rem;
  font-family: var(--font-terminal);
}

.score-part-head {
  color: #e7dcff;
  font-size: 0.82rem;
}

.score-part-head strong {
  color: #fff;
  white-space: nowrap;
}

.score-bar {
  height: 6px;
  margin: 0.55rem 0;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.08);
}

.score-bar span {
  display: block;
  height: 100%;
  background: linear-gradient(90deg, var(--neon-cyan), var(--neon-pink));
  box-shadow: 0 0 8px rgba(0, 255, 247, 0.32);
}

.score-part-meta {
  color: #8070b0;
  font-size: 0.75rem;
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
  .period-layout {
    grid-template-columns: 1fr;
  }

  .period-list {
    position: static;
  }

  .actions {
    justify-content: flex-start;
  }

  .score-breakdown-grid {
    grid-template-columns: 1fr;
  }
}
</style>
