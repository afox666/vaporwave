import axios from 'axios'

export function isTauriRuntime(): boolean {
  const g = globalThis as any
  return g.location?.protocol === 'tauri:' || !!(g.__TAURI__ || g.__TAURI_INTERNALS__)
}

// --- Types ---

export interface StockInfo {
  symbol: string
  name: string
  price: number
  change_pct: number
  score: number
  industry: string
  candidate_price?: number
  candidate_change_pct?: number
}

export interface FactorInfo {
  name: string
  category: string
  description: string
  higher_is_better: boolean
}

export type CustomFactorComponentKind =
  | 'momentum'
  | 'volatility'
  | 'ma_deviation'
  | 'volume_ratio'
  | 'rsi'
  | 'price_percentile'
  | 'pe_percentile'

export type CustomFactorField = 'close' | 'volume' | 'amount'
export type CustomFactorDirection = 'higher' | 'lower'

export interface CustomFactorComponent {
  kind: CustomFactorComponentKind
  field?: CustomFactorField | null
  window?: number | null
  short_window?: number | null
  long_window?: number | null
  direction: CustomFactorDirection
  weight: number
}

export interface CustomFactorDefinition {
  schema_version: number
  engine_version: string
  id?: string
  name: string
  description?: string
  combine: 'weighted_sum'
  normalize: 'cross_section_rank'
  components: CustomFactorComponent[]
}

export interface FactorTemplate {
  name: string
  description: string
  category: string
  definition: CustomFactorDefinition
}

export interface FactorValidationResult {
  mode: string
  factor_key: string
  factor_label: string
  summary: string
  schema_valid: boolean
  lookback: number
  engine_version: string
  estimated_valid_observation_rate: number | null
  component_missing_counts: Record<string, number>
  sample_scope?: {
    estimated?: boolean
    symbols?: number
    rebalance_dates?: number
  }
  warnings: string[]
  errors: string[]
  suggestions: string[]
}

export interface BacktestRequestConfig {
  factors: string[]
  custom_factors?: CustomFactorDefinition[]
  start_date: string
  end_date: string
  rebalance_period?: number
  top_pct?: number
  bottom_pct?: number
  pool_size?: number
  pool_mode?: string
  industry?: string
  commission_rate?: number
  stamp_tax_rate?: number
  slippage_rate?: number
  min_amount?: number
  min_listed_days?: number
  limit_pct?: number
  execution_price?: string
}

export interface BacktestConfig {
  factors: string[]
  factor_labels?: Record<string, string>
  factor_definitions?: Array<CustomFactorDefinition & {
    key?: string
    lookback?: number
  }>
  start_date: string
  end_date: string
  rebalance_period: number
  top_pct: number
  bottom_pct: number
  pool_size: number
  pool_mode?: string
  industry?: string
  pool_source?: string
  lookback_start?: string
  data_start?: string
  data_end?: string
  commission_rate?: number
  stamp_tax_rate?: number
  slippage_rate?: number
  min_amount?: number
  min_listed_days?: number
  limit_pct?: number
  execution_price?: string
  benchmark?: string
  factor_cache?: {
    enabled: boolean
    version: string
    requested: number
    cacheable: number
    hits: number
    misses: number
    unavailable: number
    writes: number
    hit_rate: number
  }
  result_cache?: {
    enabled: boolean
    version: string
    key: string
    hit: boolean
    source: string
  }
}

export interface BacktestMetrics {
  total_return: number
  annualized_return: number
  benchmark_total_return?: number
  benchmark_annualized_return?: number
  excess_total_return?: number
  max_drawdown: number
  sharpe_ratio: number
  information_ratio?: number
  num_periods: number
  periods_per_year?: number
}

export interface BacktestHolding {
  symbol: string
  weight: number
  score: number
  forward_return: number
  buyable: boolean
  sellable: boolean
  carried?: boolean
  entry_price?: number
  exit_price?: number
  factors: Record<string, number>
  factor_scores: Record<string, number>
}

export interface FactorResearch {
  observation_count: number
  date_count: number
  ic_series: Array<{ date: string; ic: number }>
  quintile_returns: number[]
  quintile_counts: number[]
}

export interface DataQualityCheck {
  name: string
  label: string
  status: 'pass' | 'warn' | 'fail'
  detail: string
  value?: unknown
}

export interface DataQualityReport {
  status: 'pass' | 'warn' | 'fail'
  summary: {
    requested_symbols: number
    loaded_symbols: number
    missing_symbols: number
    price_load_rate: number
    market_trading_days: number
    rebalance_count: number
    expected_observations: number
    valid_observations: number
    valid_observation_rate: number
    expected_pool_observations: number
    valid_pool_observations: number
    pool_observation_rate: number
    avg_symbol_day_coverage: number
    low_symbol_coverage_count: number
    stale_factor_rows: number
  }
  future_leakage: {
    factor_future_violations: number
    pe_future_violations: number
    entry_time_violations: number
    exit_before_entry: number
    exit_after_next_rebalance: number
    stale_factor_rows: number
  }
  checks: DataQualityCheck[]
  issues: string[]
  warnings: string[]
}

export interface BacktestResult {
  config: BacktestConfig
  metrics: BacktestMetrics
  portfolio: Array<{
    date: string
    long_return: number
    short_return: number
    ls_return: number
    gross_return?: number
    net_return?: number
    benchmark_return?: number
    excess_return?: number
    turnover?: number
    buy_turnover?: number
    sell_turnover?: number
    cost?: number
    net_value?: number
    benchmark_net_value?: number
    excess_net_value?: number
    cumulative_return?: number
    drawdown?: number
    n_stocks: number
    n_long?: number
    n_short?: number
    n_buy_blocked?: number
    n_sell_blocked?: number
    n_benchmark?: number
    long_holdings?: BacktestHolding[]
    short_holdings?: BacktestHolding[]
  }>
  ic_analysis: Record<string, {
    ic_mean: number
    ic_std: number
    icir: number
    ic_positive_ratio: number
  }>
  factor_research?: Record<string, FactorResearch>
  data_quality?: DataQualityReport
}

export interface BacktestTaskStatus {
  task_id: string
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled' | 'cancelling'
  progress: number
  stage: string
  message: string
  created_at: string
  updated_at: string
  cache_key?: string
  cache_hit?: boolean
  deduped_from_task_id?: string
  queue_position?: number
  running_count?: number
  max_concurrent?: number
  request?: BacktestRequestConfig
  result?: BacktestResult
  error?: string
}

export interface HistoryItem {
  id: string
  ts: string
  factors: string[]
  start: string
  end: string
  metrics: BacktestMetrics
}

export interface DailyKRecord {
  date: string
  open: number | null
  close: number | null
  high: number | null
  low: number | null
  volume: number | null
  amount: number | null
  change_pct: number | null
}

export interface StockSearchResult {
  symbol: string
  name: string
}

export interface ScanHistoryItem {
  scan_date: string
  data_date?: string
  top_n: number
  total_stocks: number
  source?: string
  coverage_count?: number
  created_at: string | null
}

export interface ScanHistoryStock {
  rank: number
  symbol: string
  name: string
  price: number | null
  change_pct: number | null
  score: number | null
  industry: string
}

export interface ScanHistoryDetail {
  scan_date: string
  stocks: ScanHistoryStock[]
}

export type ScanPeriod = 'week' | 'month' | 'quarter'
export type ScanPeriodRequest = ScanPeriod | 'all'

export interface ScanPeriodItem {
  period: ScanPeriod
  period_start: string
  period_end: string
  top_n: number
  candidate_count: number
  scan_days: number
  data_start: string
  data_end: string
  is_current: boolean
  updated_at: string
}

export interface ScanPeriodStock {
  rank: number
  symbol: string
  name: string
  industry: string
  period_score: number
  appearances: number
  best_rank: number
  avg_rank: number
  avg_daily_score: number
  score_delta: number
  return_pct: number
  first_seen_date: string
  latest_seen_date: string
  latest_price: number | null
  latest_change_pct: number | null
}

export interface ScanPeriodDetail extends ScanPeriodItem {
  stocks: ScanPeriodStock[]
}

export interface ScanPeriodRebuildResult {
  period: ScanPeriodRequest
  top_n: number
  rebuilt: number
}

// --- Tauri support ---

let _sidecarUrl: string | null = null

/**
 * Initialize Tauri HTTP client. Call this before making API requests in Tauri.
 */
export async function initTauri(): Promise<string> {
  if (_sidecarUrl) return _sidecarUrl
  const { invoke } = await import('@tauri-apps/api/core')
  const port = await invoke<number>('get_sidecar_port')
  _sidecarUrl = `http://127.0.0.1:${port}`
  return _sidecarUrl
}

function buildUrl(path: string, params?: Record<string, unknown>): string {
  const url = new URL(`${_sidecarUrl}/api${path}`)
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null && value !== '') {
        url.searchParams.set(key, String(value))
      }
    }
  }
  return url.toString()
}

/**
 * Make an HTTP request using either Tauri HTTP or axios.
 * Returns an object with `.data` property for backward compatibility with views.
 */
async function request<T>(method: string, path: string, params?: Record<string, unknown>, body?: unknown): Promise<{ data: T }> {
  if (_sidecarUrl || isTauriRuntime()) {
    if (!_sidecarUrl) {
      await initTauri()
    }
    const url = buildUrl(path, params)
    const { fetch } = await import('@tauri-apps/plugin-http')
    const opts: Record<string, unknown> = {
      method,
      connectTimeout: 120000,
    }
    if (body) {
      opts.body = JSON.stringify(body)
      opts.headers = { 'Content-Type': 'application/json' }
    }
    const resp = await fetch(url, opts)
    if (!resp.ok) {
      const text = await resp.text()
      throw new Error(`HTTP ${resp.status}: ${text}`)
    }
    const json = await resp.json() as T
    return { data: json }
  }

  // Browser dev mode: use axios through Vite proxy to the Zig sidecar.
  const resp = await axios({
    method,
    url: `/api${path}`,
    params,
    data: body,
    timeout: 120000,
  })
  return { data: resp.data as T }
}

// --- API functions ---

export const scanMarket = (topN = 100) =>
  request<{ total?: number; stocks?: StockInfo[]; source?: string; data_date?: string | null }>('GET', '/scan', { top_n: topN }).then(res => {
    const stocks = Array.isArray(res.data?.stocks) ? res.data.stocks : []
    return {
      data: {
        total: typeof res.data?.total === 'number' ? res.data.total : stocks.length,
        stocks,
        source: res.data?.source || '',
        data_date: res.data?.data_date || '',
      },
    }
  })

export const searchStock = (q: string) =>
  request<StockSearchResult[]>('GET', '/stock/search', { q }).then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getStockBasic = (symbol: string) =>
  request('GET', `/stock/${symbol}/basic`)

export const getStockProfile = (symbol: string) =>
  request('GET', `/stock/${symbol}/profile`)

export const getStockTechnical = (symbol: string) =>
  request('GET', `/stock/${symbol}/technical`)

export const getStockValuation = (symbol: string) =>
  request('GET', `/stock/${symbol}/valuation`)

export const getStockFull = (symbol: string) =>
  request('GET', `/stock/${symbol}/full`)

export const getPriceHistory = (symbol: string, days = 30) =>
  request('GET', `/stock/${symbol}/price-history`, { days })

export const getFactors = () =>
  request<FactorInfo[]>('GET', '/factors').then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getFactorTemplates = () =>
  request<FactorTemplate[]>('GET', '/factor-templates').then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const validateFactor = (payload: {
  mode?: 'schema' | 'sample'
  factors: string[]
  custom_factors: CustomFactorDefinition[]
  context?: Record<string, unknown>
}) =>
  request<FactorValidationResult>('POST', '/factors/validate', undefined, payload)

export const runBacktest = (config: BacktestRequestConfig) =>
  request<BacktestResult>('POST', '/backtest', undefined, config)

export const createBacktestTask = (config: BacktestRequestConfig) =>
  request<BacktestTaskStatus>('POST', '/backtest/tasks', undefined, config)

export const listBacktestTasks = (limit = 10) =>
  request<BacktestTaskStatus[]>('GET', '/backtest/tasks', { limit }).then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getBacktestTask = (taskId: string) =>
  request<BacktestTaskStatus>('GET', `/backtest/tasks/${taskId}`)

export const cancelBacktestTask = (taskId: string) =>
  request<BacktestTaskStatus>('POST', `/backtest/tasks/${taskId}/cancel`)

export const getHistory = () =>
  request<HistoryItem[]>('GET', '/backtest/history').then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getDailyK = (symbol: string, startDate = '', endDate = '') =>
  request<DailyKRecord[]>('GET', `/daily-k/${symbol}`, { start_date: startDate, end_date: endDate }).then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getScanHistory = () =>
  request<ScanHistoryItem[]>('GET', '/scan/history').then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getScanHistoryDetail = (date: string) =>
  request<ScanHistoryDetail>('GET', `/scan/history/${date}`).then(res => ({
    data: {
      scan_date: res.data?.scan_date || date,
      stocks: Array.isArray(res.data?.stocks) ? res.data.stocks : [],
    },
  }))

export const triggerScan = (topN = 100) =>
  request<{ scan_date: string; total: number; stocks: StockInfo[] }>('POST', '/scan/run', { top_n: topN })

export const getScanPeriods = (period: ScanPeriod = 'week', limit = 100) =>
  request<ScanPeriodItem[]>('GET', '/scan/periods', { period, limit }).then(res => ({
    data: Array.isArray(res.data) ? res.data : [],
  }))

export const getScanPeriodDetail = (period: ScanPeriod, periodStart: string) =>
  request<ScanPeriodDetail>('GET', `/scan/periods/${period}/${periodStart}`).then(res => ({
    data: {
      period,
      period_start: res.data?.period_start || periodStart,
      period_end: res.data?.period_end || '',
      top_n: Number(res.data?.top_n || 0),
      candidate_count: Number(res.data?.candidate_count || 0),
      scan_days: Number(res.data?.scan_days || 0),
      data_start: res.data?.data_start || '',
      data_end: res.data?.data_end || '',
      is_current: Boolean(res.data?.is_current),
      updated_at: res.data?.updated_at || '',
      stocks: Array.isArray(res.data?.stocks) ? res.data.stocks : [],
    },
  }))

export const rebuildScanPeriods = (period: ScanPeriodRequest = 'all', topN = 100) =>
  request<ScanPeriodRebuildResult>('POST', '/scan/periods/rebuild', { period, top_n: topN })

export default {
  scanMarket,
  searchStock,
  getStockBasic,
  getStockProfile,
  getStockTechnical,
  getStockValuation,
  getStockFull,
  getPriceHistory,
  getFactors,
  getFactorTemplates,
  validateFactor,
  runBacktest,
  createBacktestTask,
  listBacktestTasks,
  getBacktestTask,
  cancelBacktestTask,
  getHistory,
  getDailyK,
  getScanHistory,
  getScanHistoryDetail,
  triggerScan,
  getScanPeriods,
  getScanPeriodDetail,
  rebuildScanPeriods,
  initTauri,
  isTauriRuntime,
}
