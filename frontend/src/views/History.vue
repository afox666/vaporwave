<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getHistory } from '../api'
import CRTFrame from '../components/CRTFrame.vue'
import type { HistoryItem } from '../api'

const items = ref<HistoryItem[]>([])
const loading = ref(true)

onMounted(async () => {
  try {
    const res = await getHistory()
    items.value = res.data
  } catch (e) {
    console.error(e)
  }
  loading.value = false
})

function fmt(val: number | null | undefined): string {
  if (val == null) return '--'
  const sign = val >= 0 ? '+' : ''
  return `${sign}${(val * 100).toFixed(2)}%`
}
</script>

<template>
  <div class="container">
    <h2 class="section-title">&#x1F4BE; 历史回测记录</h2>

    <div v-if="loading" class="loading-glitch">LOADING HISTORY...</div>

    <div v-else-if="items.length === 0" class="vapor-card" style="text-align: center; padding: 3rem">
      <div style="font-family: var(--font-retro); color: #8070b0; font-size: 0.9rem; letter-spacing: 1px">
        暂无历史记录
      </div>
      <div style="color: #6050a0; font-size: 0.85rem; margin-top: 0.5rem">
        运行一次回测后将在这里显示结果
      </div>
    </div>

    <div v-else class="grid-2">
      <CRTFrame
        v-for="item in items"
        :key="item.id"
        :title="item.factors.join(', ')"
      >
        <div class="detail-row">
          <span>回测区间</span>
          <span>{{ item.start }} ~ {{ item.end }}</span>
        </div>
        <div class="detail-row">
          <span>因子数量</span><span>{{ item.factors.length }}</span>
        </div>
        <div class="mt-2" style="display: flex; flex-wrap: wrap; gap: 0.5rem">
          <div class="mini-metric">
            <div class="mini-label">总收益</div>
            <div class="mini-value" :class="item.metrics?.total_return >= 0 ? 'positive' : 'negative'">
              {{ fmt(item.metrics?.total_return) }}
            </div>
          </div>
          <div class="mini-metric">
            <div class="mini-label">年化</div>
            <div class="mini-value" :class="item.metrics?.annualized_return >= 0 ? 'positive' : 'negative'">
              {{ fmt(item.metrics?.annualized_return) }}
            </div>
          </div>
          <div class="mini-metric">
            <div class="mini-label">最大回撤</div>
            <div class="mini-value negative">{{ fmt(item.metrics?.max_drawdown) }}</div>
          </div>
          <div class="mini-metric">
            <div class="mini-label">夏普</div>
            <div class="mini-value">{{ item.metrics?.sharpe_ratio?.toFixed(2) }}</div>
          </div>
        </div>
        <div style="margin-top: 0.8rem; font-size: 0.8rem; color: #6050a0">
          记录时间: {{ item.ts?.substring(0, 16) }}
        </div>
      </CRTFrame>
    </div>
  </div>
</template>

<style scoped>
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

.mini-metric {
  flex: 1;
  text-align: center;
  padding: 0.5rem;
  background: rgba(0, 255, 247, 0.03);
  border: 1px solid #00fff715;
  border-radius: 3px;
  min-width: 80px;
}

.mini-label {
  font-family: var(--font-retro);
  font-size: 0.6rem;
  color: #6050a0;
  letter-spacing: 1px;
  margin-bottom: 0.3rem;
}

.mini-value {
  font-family: var(--font-terminal);
  font-size: 1.2rem;
  color: var(--neon-cyan);
}

.mini-value.positive {
  color: #ff3b3b;
}

.mini-value.negative {
  color: #00c853;
}
</style>
