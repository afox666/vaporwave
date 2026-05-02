<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getScanHistory, getScanHistoryDetail, triggerScan } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type { ScanHistoryItem, ScanHistoryStock } from '../api'

const router = useRouter()
const dates = ref<ScanHistoryItem[]>([])
const selectedDate = ref('')
const stocks = ref<ScanHistoryStock[]>([])
const loadingDates = ref(true)
const loadingDetail = ref(false)
const triggering = ref(false)

async function loadDates() {
  loadingDates.value = true
  try {
    const res = await getScanHistory()
    dates.value = res.data
    if (dates.value.length > 0 && !selectedDate.value) {
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

async function doTriggerScan() {
  triggering.value = true
  try {
    await triggerScan(100)
    await loadDates()
  } catch (e) {
    console.error(e)
  }
  triggering.value = false
}

function stockQuery(stock: ScanHistoryStock) {
  return {
    name: stock.name || undefined,
    price: stock.price != null && Number.isFinite(stock.price) ? String(stock.price) : undefined,
    score: stock.score != null && Number.isFinite(stock.score) ? String(stock.score) : undefined,
  }
}

function goToStock(stock: ScanHistoryStock | string) {
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
  loadDates()
})
</script>

<template>
  <div class="container">
    <div class="flex-between mb-3">
      <h2 class="section-title" style="margin-bottom: 0">&#x1F4C5; 扫描历史</h2>
      <button class="neon-btn" @click="doTriggerScan" :disabled="triggering">
        {{ triggering ? '扫描中...' : '手动触发扫描' }}
      </button>
    </div>

    <div v-if="loadingDates" class="loading-glitch">LOADING HISTORY...</div>

    <template v-else-if="dates.length === 0">
      <div class="vapor-card" style="text-align: center; padding: 3rem">
        <div style="font-family: var(--font-retro); color: #8070b0; font-size: 0.9rem; letter-spacing: 1px">
          暂无扫描记录
        </div>
        <div style="color: #6050a0; font-size: 0.85rem; margin-top: 0.5rem">
          点击「手动触发扫描」或等待每天 16:00 自动扫描
        </div>
      </div>
    </template>

    <template v-else>
      <div class="scan-history-layout">
        <!-- Date List Sidebar -->
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

        <!-- Detail Panel -->
        <div class="detail-panel">
          <div v-if="loadingDetail" class="loading-glitch">LOADING SCAN DATA...</div>

          <template v-else-if="stocks.length > 0">
            <!-- Top 3 Hero -->
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
                <div class="price mt-2">¥{{ stock.price?.toFixed(2) }}</div>
                <div
                  class="change"
                  :class="(stock.change_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                  style="font-family: var(--font-terminal); font-size: 1.2rem"
                >
                  {{ (stock.change_pct ?? 0) >= 0 ? '+' : '' }}{{ stock.change_pct?.toFixed(2) }}%
                </div>
                <div class="mt-2">
                  <span class="neon-tag cyan">评分: {{ stock.score?.toFixed(0) }}</span>
                  <span class="neon-tag purple" style="margin-left: 0.5rem">{{ stock.industry }}</span>
                </div>
              </div>
            </div>

            <!-- Full List -->
            <CRTFrame :title="`${selectedDate} RANKING`">
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
                    <td style="color: var(--hot-yellow)">¥{{ stock.price?.toFixed(2) }}</td>
                    <td
                      :class="(stock.change_pct ?? 0) >= 0 ? 'positive' : 'negative'"
                      style="font-family: var(--font-terminal)"
                    >
                      {{ (stock.change_pct ?? 0) >= 0 ? '+' : '' }}{{ stock.change_pct?.toFixed(2) }}%
                    </td>
                    <td>
                      <span
                        class="neon-tag"
                        :style="{
                          color: (stock.score ?? 0) >= 80 ? '#ff3b3b' : (stock.score ?? 0) >= 60 ? '#ffd700' : '#00c853',
                          borderColor: (stock.score ?? 0) >= 80 ? '#ff3b3b' : (stock.score ?? 0) >= 60 ? '#ffd700' : '#00c853',
                        }"
                      >
                        {{ stock.score?.toFixed(0) }}
                      </span>
                    </td>
                    <td style="color: #8070b0">{{ stock.industry }}</td>
                  </tr>
                </tbody>
              </table>
            </CRTFrame>
          </template>

          <div v-else class="vapor-card" style="text-align: center; padding: 2rem; color: #6050a0">
            选择左侧日期查看扫描结果
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.positive { color: #ff3b3b; }
.negative { color: #00c853; }
.change { text-shadow: 0 0 5px currentColor; }

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
}

@media (max-width: 768px) {
  .scan-history-layout {
    grid-template-columns: 1fr;
  }

  .date-list {
    position: static;
  }
}
</style>
