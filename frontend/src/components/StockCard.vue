<script setup lang="ts">
</script>

<template>
  <div class="vapor-card">
    <div class="stock-info">
      <div class="header">
        <span class="name">{{ stock.name }}</span>
        <span class="symbol">{{ stock.symbol }}</span>
      </div>
      <div class="metrics">
        <span class="price">¥{{ stock.price?.toFixed(2) }}</span>
        <span class="change" :class="stock.change_pct >= 0 ? 'positive' : 'negative'">
          {{ stock.change_pct >= 0 ? '+' : '' }}{{ stock.change_pct?.toFixed(2) }}%
        </span>
      </div>
      <div class="footer">
        <span class="industry">{{ stock.industry }}</span>
        <span class="score" :style="{ color: scoreColor }">评分: {{ stock.score?.toFixed(0) }}</span>
      </div>
    </div>
  </div>
</template>

<script lang="ts">
export default {
  props: {
    stock: {
      type: Object as () => {
        name: string
        symbol: string
        price: number
        change_pct: number
        score: number
        industry: string
      },
      required: true,
    },
  },
  computed: {
    scoreColor() {
      const s = this.stock.score || 0
      if (s >= 90) return '#ff3b3b'
      if (s >= 70) return '#00fff7'
      if (s >= 50) return '#ffd700'
      return '#00c853'
    },
  },
}
</script>

<style scoped>
.vapor-card {
  cursor: pointer;
}

.stock-info {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.name {
  font-family: var(--font-retro);
  font-size: 1.1rem;
  color: #fff;
}

.symbol {
  font-family: var(--font-terminal);
  color: var(--neon-cyan);
  font-size: 1rem;
}

.metrics {
  display: flex;
  gap: 1rem;
  align-items: baseline;
}

.price {
  font-family: var(--font-terminal);
  font-size: 1.6rem;
  color: var(--hot-yellow);
}

.change {
  font-family: var(--font-terminal);
  font-size: 1.2rem;
}

.change.positive {
  color: #ff3b3b;
}

.change.negative {
  color: #00c853;
}

.footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 0.3rem;
}

.industry {
  font-size: 0.9rem;
  color: #8070b0;
}

.score {
  font-family: var(--font-retro);
  font-size: 0.8rem;
  letter-spacing: 1px;
}
</style>
