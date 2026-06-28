import { computed, ref } from 'vue'
import type { ECharts } from 'echarts'

export type KLineZoomDirection = 'in' | 'out'

type ZoomWindow = {
  startValue: number
  endValue: number
}

const DEFAULT_VISIBLE_POINTS = 120
const MIN_VISIBLE_POINTS = 20
const ZOOM_STEP_RATIO = 0.28
const WHEEL_PIXELS_PER_POINT = 90
const MAX_WHEEL_STEP_RATIO = 0.04

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function visiblePointCount(window: ZoomWindow) {
  return Math.max(0, window.endValue - window.startValue + 1)
}

export function useKLineZoom(getChart: () => ECharts | null) {
  const pointCount = ref(0)
  const categories = ref<string[]>([])
  const zoomWindow = ref<ZoomWindow>({ startValue: 0, endValue: 0 })
  let wheelRemainder = 0

  const minVisiblePoints = computed(() => Math.min(MIN_VISIBLE_POINTS, Math.max(pointCount.value, 1)))
  const canZoomIn = computed(() => visiblePointCount(zoomWindow.value) > minVisiblePoints.value)
  const canZoomOut = computed(() => visiblePointCount(zoomWindow.value) < pointCount.value)

  function normalizeWindow(startValue: number, endValue: number): ZoomWindow {
    const total = pointCount.value
    if (total <= 0) return { startValue: 0, endValue: 0 }

    let start = clamp(Math.round(startValue), 0, total - 1)
    let end = clamp(Math.round(endValue), 0, total - 1)
    if (end < start) [start, end] = [end, start]

    const minVisible = Math.min(MIN_VISIBLE_POINTS, total)
    if (end - start + 1 < minVisible) {
      const center = Math.round((start + end) / 2)
      start = center - Math.floor(minVisible / 2)
      end = start + minVisible - 1
    }

    if (start < 0) {
      end = Math.min(total - 1, end - start)
      start = 0
    }
    if (end >= total) {
      start = Math.max(0, start - (end - total + 1))
      end = total - 1
    }

    return { startValue: start, endValue: end }
  }

  function valueToIndex(value: unknown, fallback: number) {
    if (typeof value === 'number' && Number.isFinite(value)) return Math.round(value)
    if (typeof value === 'string') {
      const index = categories.value.indexOf(value)
      if (index >= 0) return index
    }
    return fallback
  }

  function percentToIndex(value: unknown, fallback: number) {
    if (typeof value !== 'number' || !Number.isFinite(value) || pointCount.value <= 1) return fallback
    return Math.round((value / 100) * (pointCount.value - 1))
  }

  function readWindowFromChart(): ZoomWindow {
    const chart = getChart()
    const option = chart?.getOption() as { dataZoom?: Array<Record<string, unknown>> } | undefined
    const dataZoom = option?.dataZoom?.[0]
    if (!dataZoom) return zoomWindow.value

    const fallbackStart = percentToIndex(dataZoom.start, zoomWindow.value.startValue)
    const fallbackEnd = percentToIndex(dataZoom.end, zoomWindow.value.endValue)
    const start = valueToIndex(dataZoom.startValue, fallbackStart)
    const end = valueToIndex(dataZoom.endValue, fallbackEnd)
    return normalizeWindow(start, end)
  }

  function syncZoomWindow() {
    zoomWindow.value = readWindowFromChart()
  }

  function setCategories(values: string[], visiblePoints = DEFAULT_VISIBLE_POINTS) {
    categories.value = values
    pointCount.value = values.length

    const total = pointCount.value
    if (total <= 0) {
      zoomWindow.value = { startValue: 0, endValue: 0 }
      return zoomWindow.value
    }

    const visible = Math.min(total, visiblePoints)
    zoomWindow.value = {
      startValue: Math.max(0, total - visible),
      endValue: total - 1,
    }

    return zoomWindow.value
  }

  function getDataZoomOption(xAxisIndex: number[]) {
    return {
      id: 'kline-inside-zoom',
      type: 'inside',
      xAxisIndex,
      startValue: zoomWindow.value.startValue,
      endValue: zoomWindow.value.endValue,
      minValueSpan: minVisiblePoints.value,
      zoomOnMouseWheel: false,
      moveOnMouseMove: true,
      moveOnMouseWheel: false,
      preventDefaultMouseMove: true,
      throttle: 40,
    }
  }

  function applyZoomWindow(nextWindow: ZoomWindow) {
    const chart = getChart()
    if (!chart || pointCount.value <= 0) return

    const normalized = normalizeWindow(nextWindow.startValue, nextWindow.endValue)
    zoomWindow.value = normalized
    chart.dispatchAction({
      type: 'dataZoom',
      dataZoomId: 'kline-inside-zoom',
      startValue: normalized.startValue,
      endValue: normalized.endValue,
    } as any)
  }

  function zoomKLine(direction: KLineZoomDirection) {
    if (pointCount.value <= 1) return

    const current = readWindowFromChart()
    const visible = visiblePointCount(current)
    const step = Math.max(5, Math.round(visible * ZOOM_STEP_RATIO))
    const nextVisible = direction === 'in'
      ? Math.max(minVisiblePoints.value, visible - step)
      : Math.min(pointCount.value, visible + step)

    const center = Math.round((current.startValue + current.endValue) / 2)
    let startValue = center - Math.floor(nextVisible / 2)
    let endValue = startValue + nextVisible - 1

    if (startValue < 0) {
      endValue -= startValue
      startValue = 0
    }
    if (endValue >= pointCount.value) {
      startValue -= endValue - pointCount.value + 1
      endValue = pointCount.value - 1
    }

    applyZoomWindow({ startValue, endValue })
  }

  function panKLineByWheel(event: WheelEvent) {
    if (pointCount.value <= 1) return

    const absX = Math.abs(event.deltaX)
    const absY = Math.abs(event.deltaY)
    const shouldPan = absX > absY * 0.6 || event.shiftKey
    if (!shouldPan) return

    event.preventDefault()

    const rawDelta = event.shiftKey && absY > absX ? event.deltaY : event.deltaX
    if (Math.abs(rawDelta) < 0.5) return

    const current = readWindowFromChart()
    const visible = visiblePointCount(current)
    const maxStep = Math.max(1, Math.round(visible * MAX_WHEEL_STEP_RATIO))

    wheelRemainder += rawDelta / WHEEL_PIXELS_PER_POINT
    const step = clamp(Math.trunc(wheelRemainder), -maxStep, maxStep)
    if (step === 0) return

    wheelRemainder -= step
    applyZoomWindow({
      startValue: current.startValue + step,
      endValue: current.endValue + step,
    })
  }

  return {
    canZoomIn,
    canZoomOut,
    getDataZoomOption,
    panKLineByWheel,
    setCategories,
    syncZoomWindow,
    zoomKLine,
  }
}
