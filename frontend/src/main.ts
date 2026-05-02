import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './style.css'
import { initTauri, isTauriRuntime } from './api'

async function bootstrap() {
  if (isTauriRuntime()) {
    try {
      await initTauri()
    } catch (e) {
      console.error('Tauri sidecar 初始化失败', e)
    }
  }

  const app = createApp(App)
  app.use(router)
  await router.isReady()
  app.mount('#app')
}

bootstrap()
