<script setup lang="ts">
defineProps<{
  title?: string
}>()
</script>

<template>
  <div class="crt-frame">
    <div v-if="title" class="frame-header">
      <span class="frame-icon">&#x25B6;</span>
      <span class="frame-title">{{ title }}</span>
    </div>
    <div class="frame-content">
      <slot />
    </div>
  </div>
</template>

<style scoped>
.crt-frame {
  background: rgba(10, 10, 26, 0.9);
  border: 1px solid #bf00ff40;
  border-radius: 3px;
  overflow: hidden;
  position: relative;
}

.crt-frame::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: repeating-linear-gradient(
    0deg,
    rgba(0, 0, 0, 0.03) 0px,
    rgba(0, 0, 0, 0.03) 1px,
    transparent 1px,
    transparent 2px
  );
  pointer-events: none;
  z-index: 1;
}

.frame-header {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.7rem 1rem;
  background: rgba(191, 0, 255, 0.1);
  border-bottom: 1px solid #bf00ff30;
}

.frame-icon {
  color: var(--neon-purple);
  font-size: 0.8rem;
  text-shadow: var(--glow-purple);
}

.frame-title {
  font-family: var(--font-retro);
  font-size: 0.8rem;
  color: var(--neon-purple);
  text-shadow: 0 0 8px #bf00ff60;
  letter-spacing: 2px;
  text-transform: uppercase;
}

.frame-content {
  padding: 1.2rem;
  position: relative;
  z-index: 2;
}
</style>
