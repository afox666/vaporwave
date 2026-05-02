<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { useRouter } from 'vue-router'
import { scanMarket } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type { StockInfo } from '../api'

const router = useRouter()
const stocks = ref<StockInfo[]>([])
const loading = ref(false)
const topN = ref(100)
const scanProgress = ref(0)
const dataSource = ref('')
const signalDate = ref('')

const scanSteps = [
  { at: 5, text: '连接数据源...' },
  { at: 15, text: '获取A股实时行情...' },
  { at: 30, text: '筛选高成交额标的...' },
  { at: 50, text: '分析技术指标...' },
  { at: 70, text: '计算评分排名...' },
  { at: 85, text: '整理扫描结果...' },
  { at: 95, text: '即将完成...' },
]

const currentStatusText = computed(() => {
  const p = scanProgress.value
  let text = '扫描中...'
  for (const step of scanSteps) {
    if (p >= step.at) text = step.text
  }
  return text
})

function animateProgress(target: number) {
  const start = scanProgress.value
  const duration = 8000
  const startTime = performance.now()
  function tick(now: number) {
    const elapsed = now - startTime
    const t = Math.min(elapsed / duration, 1)
    const eased = 1 - Math.pow(1 - t, 3)
    scanProgress.value = Math.round(start + (target - start) * eased)
    if (t < 1) requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}

async function doScan() {
  loading.value = true
  scanProgress.value = 0
  animateProgress(95)
  try {
    const res = await scanMarket(topN.value)
    stocks.value = res.data.stocks
    dataSource.value = res.data.source || ''
    signalDate.value = res.data.data_date || ''
  } catch (e) {
    console.error(e)
  }
  scanProgress.value = 100
  loading.value = false
  await new Promise(r => setTimeout(r, 300))
  scanProgress.value = 0
}

function stockQuery(stock: StockInfo) {
  return {
    name: stock.name || undefined,
    price: Number.isFinite(stock.price) ? String(stock.price) : undefined,
    score: Number.isFinite(stock.score) ? String(stock.score) : undefined,
  }
}

function goToStock(stock: StockInfo | string) {
  if (typeof stock === 'string') {
    router.push(`/stock/${stock}`)
    return
  }
  router.push({
    path: `/stock/${stock.symbol}`,
    query: stockQuery(stock),
  })
}

onMounted(() => {
  doScan()
})
</script>

<template>
  <div class="container">
    <div class="flex-between mb-3">
      <div class="title-with-source">
        <h2 class="section-title" style="margin-bottom: 0">&#x1F50D; 市场扫描</h2>
        <span v-if="dataSource" class="source-badge" :class="dataSource">{{ dataSource === 'db' ? '本地候选池' : '实时扫描' }}</span>
        <span v-if="dataSource === 'db' && signalDate" class="source-badge signal-date">候选池基于 {{ signalDate }}</span>
      </div>
      <div class="flex-center">
        <label style="color: #8070b0; font-size: 0.9rem">Top N:</label>
        <input v-model.number="topN" type="number" class="vapor-input" style="width: 80px" min="10" max="500" />
        <button class="neon-btn" @click="doScan" :disabled="loading">
          {{ loading ? '扫描中...' : '重新扫描' }}
        </button>
      </div>
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
        <div v-for="step in scanSteps" :key="step.at" class="log-line" :class="{ active: scanProgress >= step.at }">
          <span class="log-check">{{ scanProgress >= step.at ? '[DONE]' : '[....]' }}</span>
          <span class="log-text">{{ step.text }}</span>
        </div>
      </div>
    </div>

    <template v-else>
      <!-- Top 3 Hero -->
      <div v-if="stocks.length >= 3" class="grid-3 mb-3">
        <div
          v-for="(stock, i) in stocks.slice(0, 3)"
          :key="stock.symbol"
          class="stock-hero-card"
          @click="goToStock(stock)"
        >
          <span class="rank">#{{ i + 1 }}</span>
          <div class="name">{{ stock.name }}</div>
          <div class="symbol">{{ stock.symbol }}</div>
          <div class="price mt-2">¥{{ stock.price?.toFixed(2) }}</div>
          <div class="change" :class="stock.change_pct >= 0 ? 'positive' : 'negative'" style="font-family: var(--font-terminal); font-size: 1.2rem">
            {{ stock.change_pct >= 0 ? '+' : '' }}{{ stock.change_pct?.toFixed(2) }}%
          </div>
          <div class="mt-2">
            <span class="neon-tag cyan">评分: {{ stock.score?.toFixed(0) }}</span>
            <span class="neon-tag purple" style="margin-left: 0.5rem">{{ stock.industry }}</span>
          </div>
        </div>
      </div>

      <!-- Full List -->
      <CRTFrame title="FULL RANKING">
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
            <tr v-for="(stock, i) in stocks" :key="stock.symbol" @click="goToStock(stock)" style="cursor: pointer">
              <td>{{ i + 1 }}</td>
              <td style="color: var(--neon-cyan)">{{ stock.symbol }}</td>
              <td style="color: #fff">{{ stock.name }}</td>
              <td style="color: var(--hot-yellow)">¥{{ stock.price?.toFixed(2) }}</td>
              <td :class="stock.change_pct >= 0 ? 'positive' : 'negative'" style="font-family: var(--font-terminal)">
                {{ stock.change_pct >= 0 ? '+' : '' }}{{ stock.change_pct?.toFixed(2) }}%
              </td>
              <td>
                <span class="neon-tag" :style="{ color: stock.score >= 80 ? '#ff3b3b' : stock.score >= 60 ? '#ffd700' : '#00c853', borderColor: stock.score >= 80 ? '#ff3b3b' : stock.score >= 60 ? '#ffd700' : '#00c853' }">
                  {{ stock.score?.toFixed(0) }}
                </span>
              </td>
              <td style="color: #8070b0">{{ stock.industry }}</td>
            </tr>
          </tbody>
        </table>
      </CRTFrame>
    </template>
  </div>
</template>

<style scoped>
.positive { color: #ff3b3b; }
.negative { color: #00c853; }

.change {
  text-shadow: 0 0 5px currentColor;
}

.title-with-source {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-wrap: wrap;
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

.source-badge.signal-date {
  color: var(--neon-cyan);
  border: 1px solid #00fff740;
  background: rgba(0, 255, 247, 0.05);
}

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
</style>
