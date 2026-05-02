<script setup lang="ts">
defineProps<{
  value: number
  max?: number
  color?: string
  label?: string
}>()
</script>

<template>
  <div class="neon-bar">
    <div v-if="label" class="bar-label">
      <span>{{ label }}</span>
      <span>{{ value }}{{ max ? ` / ${max}` : '' }}</span>
    </div>
    <div class="bar-track">
      <div
        class="bar-fill"
        :style="{
          width: `${Math.min(100, (value / (max || 100)) * 100)}%`,
          background: `linear-gradient(90deg, ${color || '#ff007f'}, ${color || '#ff007f'}80)`,
          boxShadow: `0 0 10px ${color || '#ff007f'}60`
        }"
      ></div>
    </div>
  </div>
</template>

<style scoped>
.neon-bar {
  margin-bottom: 0.8rem;
}

.bar-label {
  display: flex;
  justify-content: space-between;
  font-family: var(--font-terminal);
  font-size: 0.95rem;
  color: #a090d0;
  margin-bottom: 0.3rem;
}

.bar-track {
  height: 6px;
  background: rgba(191, 0, 255, 0.15);
  border-radius: 3px;
  overflow: hidden;
}

.bar-fill {
  height: 100%;
  border-radius: 3px;
  transition: width 0.8s ease;
}
</style>
