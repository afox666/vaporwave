import { createMemoryHistory, createRouter, createWebHistory } from 'vue-router'
import Backtest from '../views/Backtest.vue'
import Dashboard from '../views/Dashboard.vue'
import History from '../views/History.vue'
import Scan from '../views/Scan.vue'
import ScanHistory from '../views/ScanHistory.vue'
import ScanPeriods from '../views/ScanPeriods.vue'
import StockDetail from '../views/StockDetail.vue'
import StockHistory from '../views/StockHistory.vue'

const isTauri = typeof window !== 'undefined' && window.location.protocol === 'tauri:'

const router = createRouter({
  history: isTauri ? createMemoryHistory() : createWebHistory(),
  routes: [
    { path: '/', component: Dashboard },
    { path: '/scan', component: Scan },
    { path: '/scan/history', component: ScanHistory },
    { path: '/scan/periods', component: ScanPeriods },
    { path: '/stock/:symbol', component: StockDetail },
    { path: '/backtest', component: Backtest },
    { path: '/history', component: History },
    { path: '/history/:symbol', component: StockHistory },
  ],
})

if (isTauri) {
  const initialPath = window.location.hash.replace(/^#/, '') || '/'
  router.replace(initialPath)
}

export default router
