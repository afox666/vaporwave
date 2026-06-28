<script setup lang="ts">
import { ref, onMounted, watch, computed } from 'vue'
import { useRouter } from 'vue-router'
import { scanMarket, getFactors, searchStock, getScanHistory, getScanHistoryDetail } from '../api'
import StockCard from '../components/StockCard.vue'
import CRTFrame from '../components/CRTFrame.vue'
import type { StockInfo, FactorInfo, StockSearchResult } from '../api'

const router = useRouter()
const stocks = ref<StockInfo[]>([])
const factors = ref<FactorInfo[]>([])
const loading = ref(true)
const dataSource = ref('')
const signalDate = ref('')
const scanProgress = ref(0)
const loadMode = ref<'snapshot' | 'scan'>('snapshot')
const searchQuery = ref('')
const searchResults = ref<StockSearchResult[]>([])
const showDropdown = ref(false)
let searchTimer: ReturnType<typeof setTimeout> | null = null
let progressRunId = 0

const scanSteps = [
  { at: 5, text: '连接数据源...' },
  { at: 15, text: '获取A股实时行情...' },
  { at: 30, text: '筛选高成交额标的...' },
  { at: 50, text: '分析技术指标...' },
  { at: 70, text: '计算评分排名...' },
  { at: 85, text: '整理扫描结果...' },
  { at: 95, text: '即将完成...' },
]

const snapshotSteps = [
  { at: 15, text: '连接历史快照...' },
  { at: 45, text: '读取最近榜单...' },
  { at: 75, text: '整理市场快照...' },
  { at: 95, text: '即将完成...' },
]

const activeLoadSteps = computed(() => loadMode.value === 'scan' ? scanSteps : snapshotSteps)

const currentStatusText = computed(() => {
  const p = scanProgress.value
  let text = loadMode.value === 'scan' ? '扫描中...' : '读取中...'
  for (const step of activeLoadSteps.value) {
    if (p >= step.at) text = step.text
  }
  return text
})

const sourceLabel = computed(() => {
  if (dataSource.value === 'scan') return '实时扫描'
  if (dataSource.value === 'history') return '历史快照'
  if (dataSource.value === 'db') return '本地候选池'
  return dataSource.value
})

function animateProgress(target: number) {
  const runId = ++progressRunId
  const start = scanProgress.value
  const duration = 8000 // ms for full animation
  const startTime = performance.now()

  function tick(now: number) {
    if (runId !== progressRunId) return
    const elapsed = now - startTime
    const t = Math.min(elapsed / duration, 1)
    // Ease out: starts fast, slows down
    const eased = 1 - Math.pow(1 - t, 3)
    scanProgress.value = Math.round(start + (target - start) * eased)
    if (t < 1) requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}

function finishProgress() {
  progressRunId += 1
  scanProgress.value = 100
}

function emptyMarketSnapshot() {
  return { data: { total: 0, stocks: [], source: '', data_date: '' } }
}

async function loadCachedMarketSnapshot() {
  const history = await getScanHistory()
  const latest = history.data[0]
  if (!latest) return emptyMarketSnapshot()

  const detail = await getScanHistoryDetail(latest.scan_date)
  const cachedStocks: StockInfo[] = detail.data.stocks.map(stock => ({
    symbol: stock.symbol,
    name: stock.name,
    price: stock.price ?? 0,
    change_pct: stock.change_pct ?? 0,
    score: stock.score ?? 0,
    industry: stock.industry || 'N/A',
  }))

  return {
    data: {
      total: latest.total_stocks || cachedStocks.length,
      stocks: cachedStocks,
      source: cachedStocks.length > 0 ? 'history' : '',
      data_date: latest.data_date || latest.scan_date || '',
    },
  }
}

function applyMarketSnapshot(snapshot: Awaited<ReturnType<typeof scanMarket>>) {
  signalDate.value = snapshot.data.data_date || ''
  stocks.value = snapshot.data.stocks || []
  dataSource.value = snapshot.data.source || ''
}

async function loadDashboardSnapshot(mode: 'snapshot' | 'scan') {
  loading.value = true
  loadMode.value = mode
  scanProgress.value = 0
  animateProgress(95)

  const marketPromise = mode === 'scan' ? scanMarket(100) : loadCachedMarketSnapshot()
  const factorPromise = factors.value.length > 0
    ? Promise.resolve({ data: factors.value })
    : getFactors()

  const [marketRes, factorRes] = await Promise.all([
    marketPromise.catch(e => {
      console.error(e)
      return stocks.value.length > 0 ? null : emptyMarketSnapshot()
    }),
    factorPromise.catch(e => {
      console.error(e)
      return { data: factors.value }
    }),
  ])

  if (marketRes) {
    applyMarketSnapshot(marketRes)
  }
  factors.value = factorRes.data

  finishProgress()
  await new Promise(r => setTimeout(r, 300))
  loading.value = false
}

onMounted(() => {
  loadDashboardSnapshot('snapshot')
})

function refreshMarketSnapshot() {
  if (loading.value) return
  loadDashboardSnapshot('scan')
}

function stockQuery(stock: StockInfo) {
  return {
    name: stock.name || undefined,
    price: Number.isFinite(stock.price) ? String(stock.price) : undefined,
    score: Number.isFinite(stock.score) ? String(stock.score) : undefined,
  }
}

function goToStock(stock: StockInfo | string) {
  showDropdown.value = false
  searchQuery.value = ''
  searchResults.value = []
  if (typeof stock === 'string') {
    router.push(`/stock/${stock}`)
    return
  }
  router.push({
    path: `/stock/${stock.symbol}`,
    query: stockQuery(stock),
  })
}

function doSearch() {
  const q = searchQuery.value.trim()
  if (!q) return
  // If it looks like a pure 6-digit code, go directly
  if (/^\d{6}$/.test(q)) {
    goToStock(q)
    return
  }
  // Otherwise, if there are search results, go to the first one
  if (searchResults.value.length > 0) {
    goToStock(searchResults.value[0].symbol)
  }
}

watch(searchQuery, (val) => {
  if (searchTimer) clearTimeout(searchTimer)
  const q = val.trim()
  if (q.length === 0) {
    searchResults.value = []
    showDropdown.value = false
    return
  }
  searchTimer = setTimeout(async () => {
    try {
      const res = await searchStock(q)
      searchResults.value = res.data
      showDropdown.value = res.data.length > 0
    } catch {
      searchResults.value = []
      showDropdown.value = false
    }
  }, 300)
})

function onBlur() {
  // Delay hiding so click on dropdown item can fire first
  setTimeout(() => { showDropdown.value = false }, 200)
}

function goBacktest() {
  router.push('/backtest')
}

function goHistory() {
  router.push('/history/000001')
}
</script>

<template>
  <div class="container">
    <!-- Hero -->
    <div class="hero">
      <h1 class="neon-title chroma-hover">VAPORWAVE QUANT</h1>
      <p class="neon-subtitle mt-2">量化分析平台 // QUANTITATIVE ANALYSIS TERMINAL</p>

      <!-- Search -->
      <div class="flex-center mt-4" style="position: relative">
        <div class="search-wrapper">
          <input
            v-model="searchQuery"
            class="vapor-input"
            placeholder="输入股票代码或名称..."
            @keyup.enter="doSearch"
            @focus="showDropdown = searchResults.length > 0"
            @blur="onBlur"
            style="width: 260px"
          />
          <div v-if="showDropdown" class="search-dropdown">
            <div
              v-for="item in searchResults"
              :key="item.symbol"
              class="search-item"
              @mousedown.prevent="goToStock(item.symbol)"
            >
              <span class="search-symbol">{{ item.symbol }}</span>
              <span class="search-name">{{ item.name }}</span>
            </div>
          </div>
        </div>
        <button class="neon-btn primary" @click="doSearch">查 询</button>
      </div>

      <!-- Quick Actions -->
      <div class="flex-center mt-4">
        <button class="neon-btn pulse" @click="goBacktest">
          <span>&#x26A1;</span> 因子回测
        </button>
        <button class="neon-btn" @click="goHistory">
          <span>&#x1F4C8;</span> 历史数据
        </button>
      </div>
    </div>

    <!-- Market Snapshot -->
    <div class="mt-4">
      <div class="section-title-row">
        <div class="title-with-source">
          <h2 class="section-title" style="margin-bottom: 0">&#x1F4C8; 市场快照</h2>
          <div class="source-badges">
            <span v-if="dataSource" class="source-badge" :class="dataSource">{{ sourceLabel }}</span>
            <span v-if="signalDate" class="source-badge signal-date">数据 {{ signalDate }}</span>
          </div>
        </div>
        <button class="neon-btn snapshot-refresh-btn" @click="refreshMarketSnapshot" :disabled="loading">
          {{ loading && loadMode === 'scan' ? '扫描中...' : '刷新扫描' }}
        </button>
      </div>

      <div v-if="loading" class="scan-progress-card">
        <div class="scan-animation">
          <div class="scan-spinner"></div>
          <div class="scan-info">
            <div class="scan-status-text">{{ currentStatusText }}</div>
            <div class="progress-bar-container">
              <div class="progress-bar" :style="{ width: scanProgress + '%' }"></div>
              <div class="progress-percent">{{ scanProgress }}%</div>
            </div>
          </div>
        </div>
        <div class="scan-terminal-log">
          <div v-for="step in activeLoadSteps" :key="step.at" class="log-line" :class="{ active: scanProgress >= step.at }">
            <span class="log-check">{{ scanProgress >= step.at ? '[DONE]' : '[....]' }}</span>
            <span class="log-text">{{ step.text }}</span>
          </div>
        </div>
      </div>

      <div v-else class="grid-3">
        <StockCard
          v-for="stock in stocks.slice(0, 6)"
          :key="stock.symbol"
          :stock="stock"
          @click="goToStock(stock)"
        />
      </div>
    </div>

    <!-- Available Factors -->
    <div class="mt-4" v-if="factors.length > 0">
      <h2 class="section-title">&#x26A1; 可用因子</h2>
      <CRTFrame title="FACTOR LIBRARY">
        <div class="factor-grid">
          <div
            v-for="f in factors"
            :key="f.name"
            class="factor-item"
            @click="goBacktest"
          >
            <span class="factor-name">{{ f.name }}</span>
            <span class="factor-desc">{{ f.description }}</span>
            <span class="neon-tag" :class="f.category">{{ f.category }}</span>
          </div>
        </div>
      </CRTFrame>
    </div>
  </div>
</template>

<style scoped>
.scan-progress-card {
  background: rgba(10, 10, 26, 0.9);
  border: 1px solid #bf00ff40;
  border-radius: 3px;
  padding: 1.5rem;
}

.scan-animation {
  display: flex;
  align-items: center;
  gap: 1.5rem;
  margin-bottom: 1rem;
}

.scan-spinner {
  width: 48px;
  height: 48px;
  border: 3px solid #bf00ff20;
  border-top-color: var(--neon-cyan);
  border-radius: 50%;
  animation: spin 1s linear infinite;
  flex-shrink: 0;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.scan-info {
  flex: 1;
  min-width: 0;
}

.scan-status-text {
  font-family: var(--font-terminal);
  font-size: 1rem;
  color: var(--neon-cyan);
  text-shadow: 0 0 8px #00fff740;
  margin-bottom: 0.8rem;
}

.progress-bar-container {
  position: relative;
  height: 24px;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid #bf00ff30;
  border-radius: 2px;
  overflow: hidden;
}

.progress-bar {
  height: 100%;
  background: linear-gradient(90deg, #00fff7, #bf00ff);
  border-radius: 2px;
  transition: width 0.3s ease;
  box-shadow: 0 0 10px #00fff740;
}

.progress-percent {
  position: absolute;
  right: 8px;
  top: 50%;
  transform: translateY(-50%);
  font-family: var(--font-terminal);
  font-size: 0.85rem;
  color: #fff;
  text-shadow: 0 0 4px rgba(0, 0, 0, 0.8);
}

.scan-terminal-log {
  border-top: 1px solid #bf00ff30;
  padding-top: 0.8rem;
  display: flex;
  flex-wrap: wrap;
  gap: 0.3rem 1rem;
}

.log-line {
  font-family: var(--font-terminal);
  font-size: 0.8rem;
  color: #6050a0;
  transition: color 0.3s ease;
}

.log-line.active {
  color: #ff3b3b;
}

.log-check {
  margin-right: 0.3rem;
  font-weight: bold;
}

.log-line.active .log-check {
  text-shadow: 0 0 6px #ff3b3b60;
}

.section-title-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 1rem;
}

.title-with-source {
  display: flex;
  align-items: center;
  gap: 0.8rem;
  min-width: 0;
  flex-wrap: wrap;
}

.source-badges {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  flex-wrap: wrap;
  justify-content: flex-start;
}

.source-badge {
  font-family: var(--font-retro);
  font-size: 0.7rem;
  padding: 0.3rem 0.8rem;
  border-radius: 2px;
  letter-spacing: 1px;
}

.source-badge.db {
  color: #ff3b3b;
  border: 1px solid #ff3b3b40;
  background: rgba(255, 59, 59, 0.05);
}

.source-badge.scan {
  color: #ffd700;
  border: 1px solid #ffd70040;
  background: rgba(255, 215, 0, 0.05);
}

.source-badge.history {
  color: #00fff7;
  border: 1px solid #00fff740;
  background: rgba(0, 255, 247, 0.05);
}

.source-badge.signal-date {
  color: var(--neon-cyan);
  border: 1px solid #00fff740;
  background: rgba(0, 255, 247, 0.05);
}

.snapshot-refresh-btn {
  flex-shrink: 0;
  padding: 0.55rem 1rem;
  font-size: 0.75rem;
}

.snapshot-refresh-btn:disabled {
  cursor: wait;
  opacity: 0.55;
}

.factor-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
  gap: 1rem;
}

.factor-item {
  padding: 0.8rem;
  background: rgba(191, 0, 255, 0.05);
  border: 1px solid #bf00ff20;
  border-radius: 3px;
  cursor: pointer;
  transition: all 0.3s ease;
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}

.factor-item:hover {
  border-color: var(--neon-cyan);
  background: rgba(0, 255, 247, 0.05);
}

.factor-name {
  font-family: var(--font-retro);
  font-size: 0.8rem;
  color: var(--neon-cyan);
  letter-spacing: 1px;
}

.factor-desc {
  font-size: 0.9rem;
  color: #a090d0;
}

.neon-tag.momentum {
  color: var(--neon-pink);
  border-color: var(--neon-pink);
}

.neon-tag.value {
  color: var(--hot-yellow);
  border-color: var(--hot-yellow);
}

.neon-tag.volatility {
  color: var(--neon-purple);
  border-color: var(--neon-purple);
}

.neon-tag.volume {
  color: #ff3b3b;
  border-color: #ff3b3b;
}

.neon-tag.technical {
  color: var(--neon-cyan);
  border-color: var(--neon-cyan);
}

.search-wrapper {
  position: relative;
  display: inline-block;
}

.search-dropdown {
  position: absolute;
  top: 100%;
  left: 0;
  width: 260px;
  max-height: 300px;
  overflow-y: auto;
  background: #1a0a2e;
  border: 1px solid var(--neon-cyan);
  border-top: none;
  border-radius: 0 0 4px 4px;
  z-index: 100;
  box-shadow: 0 4px 20px rgba(0, 255, 247, 0.15);
}

.search-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.5rem 0.8rem;
  cursor: pointer;
  transition: background 0.2s;
}

.search-item:hover {
  background: rgba(0, 255, 247, 0.1);
}

.search-symbol {
  font-family: var(--font-retro);
  font-size: 0.85rem;
  color: var(--neon-cyan);
  letter-spacing: 1px;
}

.search-name {
  font-size: 0.85rem;
  color: #a090d0;
}
</style>
