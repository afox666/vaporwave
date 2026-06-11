<script setup lang="ts">
import { computed, ref } from 'vue'
import {
  clearStoredBrowserApiBaseUrl,
  getDefaultBrowserApiBaseUrl,
  getStoredBrowserApiBaseUrl,
  isTauriRuntime,
  setStoredBrowserApiBaseUrl,
} from './api'

const settingsOpen = ref(false)
const apiBaseInput = ref('')
const savedApiBase = ref(getStoredBrowserApiBaseUrl())
const settingsMessage = ref('')
const defaultApiBase = getDefaultBrowserApiBaseUrl()

const apiBaseLabel = computed(() => {
  if (isTauriRuntime()) return '桌面 sidecar'
  return savedApiBase.value || defaultApiBase || '当前域名 /api'
})

const apiBaseMode = computed(() => {
  if (isTauriRuntime()) return '桌面'
  return savedApiBase.value ? '自定义' : '默认'
})

function openSettings() {
  savedApiBase.value = getStoredBrowserApiBaseUrl()
  apiBaseInput.value = savedApiBase.value || defaultApiBase
  settingsMessage.value = ''
  settingsOpen.value = true
}

function closeSettings() {
  settingsOpen.value = false
}

function reloadSoon() {
  window.setTimeout(() => {
    window.location.reload()
  }, 250)
}

function saveApiBase() {
  const saved = setStoredBrowserApiBaseUrl(apiBaseInput.value)
  savedApiBase.value = saved
  apiBaseInput.value = saved
  settingsMessage.value = saved ? '已保存到此浏览器，正在刷新页面。' : '已清除本地设置，正在刷新页面。'
  reloadSoon()
}

function clearApiBase() {
  clearStoredBrowserApiBaseUrl()
  savedApiBase.value = ''
  apiBaseInput.value = defaultApiBase
  settingsMessage.value = '已恢复默认后端地址，正在刷新页面。'
  reloadSoon()
}
</script>

<template>
  <div class="crt-overlay"></div>
  <div class="vhs-noise"></div>
  <nav class="vapor-nav">
    <div class="logo">VAPORWAVE QUANT</div>
    <router-link to="/">仪表盘</router-link>
    <router-link to="/scan/history">扫描历史</router-link>
    <router-link to="/scan/periods">周期榜单</router-link>
    <router-link to="/backtest">因子回测</router-link>
    <router-link to="/history">历史记录</router-link>
    <router-link to="/history/000001">历史数据</router-link>
    <div class="nav-spacer"></div>
    <button class="api-settings-trigger" type="button" @click="openSettings">
      <span class="api-settings-status">{{ apiBaseMode }}</span>
      设置
    </button>
  </nav>
  <main>
    <router-view />
  </main>

  <div v-if="settingsOpen" class="settings-backdrop" @click.self="closeSettings">
    <section class="settings-dialog" role="dialog" aria-modal="true" aria-labelledby="settings-title">
      <header class="settings-header">
        <div>
          <h2 id="settings-title">后端设置</h2>
          <p>当前后端：{{ apiBaseLabel }}</p>
        </div>
        <button class="settings-close" type="button" aria-label="关闭设置" @click="closeSettings">×</button>
      </header>

      <label class="settings-field">
        <span>后端地址</span>
        <input
          v-model.trim="apiBaseInput"
          class="vapor-input settings-input"
          type="url"
          placeholder="https://example.trycloudflare.com"
          autocomplete="off"
        />
      </label>

      <p class="settings-note">
        地址会保存在当前浏览器的 localStorage 中。填写 origin 即可，末尾的 /api 会自动处理。
      </p>

      <p v-if="settingsMessage" class="settings-message">{{ settingsMessage }}</p>

      <footer class="settings-actions">
        <button class="neon-btn primary" type="button" @click="saveApiBase">保存并刷新</button>
        <button class="neon-btn" type="button" @click="clearApiBase">恢复默认</button>
        <button class="settings-secondary" type="button" @click="closeSettings">取消</button>
      </footer>
    </section>
  </div>
</template>
