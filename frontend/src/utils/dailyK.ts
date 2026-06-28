type VolumeRecord = {
  close: number | null
  volume: number | null
  amount?: number | null
}

function isPositiveFinite(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
}

function detectedVolumeScale(record: VolumeRecord): number | null {
  if (!isPositiveFinite(record.volume) || !isPositiveFinite(record.close) || !isPositiveFinite(record.amount)) {
    return null
  }

  const impliedVolume = record.amount / record.close
  if (!isPositiveFinite(impliedVolume)) return null

  const ratio = impliedVolume / record.volume
  if (ratio >= 50 && ratio <= 150) return 100
  if (ratio >= 0.5 && ratio <= 1.5) return 1
  return null
}

function shouldScaleFromNeighbor(volume: number | null, neighborVolume: number | null) {
  if (!isPositiveFinite(volume) || !isPositiveFinite(neighborVolume)) return false

  const rawRatio = neighborVolume / volume
  const scaledRatio = (volume * 100) / neighborVolume
  return rawRatio >= 20 && rawRatio <= 200 && scaledRatio >= 0.2 && scaledRatio <= 5
}

export function normalizeDailyKVolumes<T extends VolumeRecord>(records: T[]): T[] {
  const normalized = records.map(record => ({ ...record }))

  for (const record of normalized) {
    const scale = detectedVolumeScale(record)
    if (scale && scale > 1.5 && isPositiveFinite(record.volume)) {
      record.volume *= scale
    }
  }

  let prevVolume: number | null = null
  for (const record of normalized) {
    if (!isPositiveFinite(record.volume)) continue
    if (record.amount == null && shouldScaleFromNeighbor(record.volume, prevVolume)) {
      record.volume *= 100
    }
    prevVolume = record.volume
  }

  let nextVolume: number | null = null
  for (let i = normalized.length - 1; i >= 0; i -= 1) {
    const record = normalized[i]
    if (!isPositiveFinite(record.volume)) continue
    if (record.amount == null && shouldScaleFromNeighbor(record.volume, nextVolume)) {
      record.volume *= 100
    }
    nextVolume = record.volume
  }

  return normalized
}
