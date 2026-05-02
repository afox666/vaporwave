<script setup lang="ts">
</script>

<template>
  <div class="crt-overlay"></div>
  <div class="vhs-noise"></div>
  <nav class="vapor-nav">
    <div class="logo">VAPORWAVE QUANT</div>
    <router-link to="/">仪表盘</router-link>
    <router-link to="/scan/history">扫描历史</router-link>
    <router-link to="/backtest">因子回测</router-link>
    <router-link to="/history">历史记录</router-link>
    <router-link to="/history/000001">历史数据</router-link>
  </nav>
  <main>
    <router-view />
  </main>
</template>
