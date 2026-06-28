<script setup lang="ts">
import type { KLineZoomDirection } from '../composables/useKLineZoom'

defineProps<{
  canZoomIn: boolean
  canZoomOut: boolean
}>()

const emit = defineEmits<{
  zoom: [direction: KLineZoomDirection]
}>()
</script>

<template>
  <div class="kline-zoom-controls" aria-label="K线缩放控制">
    <button
      type="button"
      class="kline-zoom-btn"
      :disabled="!canZoomIn"
      aria-label="放大K线"
      @click="emit('zoom', 'in')"
    >
      +
    </button>
    <button
      type="button"
      class="kline-zoom-btn"
      :disabled="!canZoomOut"
      aria-label="缩小K线"
      @click="emit('zoom', 'out')"
    >
      -
    </button>
  </div>
</template>

<style scoped>
.kline-zoom-controls {
  position: absolute;
  right: 0.9rem;
  bottom: 0.9rem;
  z-index: 3;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  padding: 0.3rem;
  border: 1px solid #00fff740;
  border-radius: 999px;
  background: rgba(10, 10, 26, 0.46);
  box-shadow: 0 0 18px #00fff720;
  backdrop-filter: blur(8px);
}

.kline-zoom-btn {
  width: 2rem;
  height: 2rem;
  border: 1px solid #00fff766;
  border-radius: 50%;
  background: rgba(26, 10, 46, 0.58);
  color: #f0e6ff;
  font-family: var(--font-retro);
  font-size: 1.2rem;
  line-height: 1;
  cursor: pointer;
  text-shadow: 0 0 8px #00fff780;
  transition: transform 0.16s ease, border-color 0.16s ease, background 0.16s ease, opacity 0.16s ease;
}

.kline-zoom-btn:hover:not(:disabled) {
  border-color: var(--neon-cyan);
  background: rgba(0, 255, 247, 0.16);
  transform: scale(1.06);
}

.kline-zoom-btn:active:not(:disabled) {
  transform: scale(0.96);
}

.kline-zoom-btn:disabled {
  cursor: default;
  opacity: 0.38;
}

@media (max-width: 640px) {
  .kline-zoom-controls {
    right: 0.5rem;
    bottom: 0.55rem;
  }
}
</style>
