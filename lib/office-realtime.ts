export const OFFICE_MOVEMENT_INTERVAL_MS = 125
export const OFFICE_EVENT_MAX_BYTES = 512

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const DIRECTIONS = ['up', 'down', 'left', 'right'] as const

export type OfficeDirection = typeof DIRECTIONS[number]

export interface OfficePresence {
  userId: string
  workspaceId: string
  officeId: string
  sessionId: string
  joinedAt: string
}

export interface PlayerMoved {
  officeId: string
  sessionId: string
  x: number
  y: number
  direction: OfficeDirection
  sequence: number
}

export type PlayerStopped = PlayerMoved

export interface OfficeLayoutUpdated {
  officeId: string
  mapVersion: number
}

export interface OfficeBroadcastPayloads {
  player_moved: PlayerMoved
  player_stopped: PlayerStopped
  office_layout_updated: OfficeLayoutUpdated
}

export function officeTopic(workspaceId: string): `office:${string}` {
  if (!UUID.test(workspaceId)) throw new TypeError('Invalid workspace ID')
  return `office:${workspaceId}`
}

function recordWithKeys(value: unknown, keys: readonly string[]): value is Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const actualKeys = Object.keys(value)
  if (actualKeys.length !== keys.length || !actualKeys.every(key => keys.includes(key))) return false
  return actualKeys.every(key => {
    const field = (value as Record<string, unknown>)[key]
    return typeof field === 'number' || (typeof field === 'string' && field.length <= OFFICE_EVENT_MAX_BYTES)
  }) && new TextEncoder().encode(JSON.stringify(value)).length <= OFFICE_EVENT_MAX_BYTES
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value)
}

function isCoordinate(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1
}

export function isOfficePresence(
  value: unknown,
  context: { workspaceId: string; officeId: string; presenceKey: string },
): value is OfficePresence {
  return recordWithKeys(value, ['userId', 'workspaceId', 'officeId', 'sessionId', 'joinedAt'])
    && isUuid(value.userId)
    && isUuid(value.workspaceId) && value.workspaceId === context.workspaceId
    && isUuid(value.officeId) && value.officeId === context.officeId
    && isUuid(value.sessionId) && value.sessionId === context.presenceKey
    && typeof value.joinedAt === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value.joinedAt)
    && Number.isFinite(Date.parse(value.joinedAt))
    && new Date(value.joinedAt).toISOString() === value.joinedAt
}

export function isOfficeBroadcast<Event extends keyof OfficeBroadcastPayloads>(
  event: Event,
  value: unknown,
  context: { officeId: string; lastSequence?: number },
): value is OfficeBroadcastPayloads[Event] {
  if (event === 'office_layout_updated') {
    return recordWithKeys(value, ['officeId', 'mapVersion'])
      && isUuid(value.officeId) && value.officeId === context.officeId
      && typeof value.mapVersion === 'number'
      && Number.isInteger(value.mapVersion) && value.mapVersion >= 1 && value.mapVersion <= 2147483647
  }
  if (event !== 'player_moved' && event !== 'player_stopped') return false
  return recordWithKeys(value, ['officeId', 'sessionId', 'x', 'y', 'direction', 'sequence'])
    && isUuid(value.officeId) && value.officeId === context.officeId
    && isUuid(value.sessionId)
    && isCoordinate(value.x) && isCoordinate(value.y)
    && DIRECTIONS.some(direction => direction === value.direction)
    && typeof value.sequence === 'number'
    && Number.isSafeInteger(value.sequence) && value.sequence >= 0
    && value.sequence > (context.lastSequence ?? -1)
}
