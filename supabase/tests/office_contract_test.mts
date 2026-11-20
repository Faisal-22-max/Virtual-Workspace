import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { isOfficeBroadcast, isOfficePresence, officeTopic } from '../../lib/office-realtime.js'

const workspaceId = randomUUID()
const officeId = randomUUID()
const sessionId = randomUUID()
const context = { officeId, lastSequence: 4 }
const movement = { officeId, sessionId, x: 0, y: 1, direction: 'down', sequence: 5 }

assert.equal(officeTopic(workspaceId), `office:${workspaceId}`)
assert.throws(() => officeTopic(workspaceId + '\n'), /Invalid workspace ID/)
assert(isOfficeBroadcast('player_moved', movement, context))
assert(isOfficeBroadcast('player_stopped', { ...movement, sequence: 6 }, context))
assert(isOfficeBroadcast('player_moved', { ...movement, sequence: 0 }, { officeId }))
assert(isOfficeBroadcast('office_layout_updated', { officeId, mapVersion: 2 }, context))

for (const patch of [
  { officeId: randomUUID() }, { sessionId: 'bad' }, { x: NaN }, { x: -0.01 },
  { y: 1.01 }, { y: Infinity }, { x: '0.1' }, { direction: 'north' },
  { direction: 'x'.repeat(600) }, { sequence: -1 }, { sequence: 4 },
  { sequence: 5.5 }, { sequence: Number.MAX_SAFE_INTEGER + 1 }, { userId: randomUUID() },
]) {
  assert(!isOfficeBroadcast('player_moved', { ...movement, ...patch }, context))
}
for (const mapVersion of [-1, 0, 2.5, Infinity, 2147483648]) {
  assert(!isOfficeBroadcast('office_layout_updated', { officeId, mapVersion }, context))
}

const presence = { officeId, workspaceId, sessionId, userId: randomUUID(), joinedAt: new Date().toISOString() }
const presenceContext = { officeId, workspaceId, presenceKey: sessionId }
assert(isOfficePresence(presence, presenceContext))
for (const patch of [
  { workspaceId: randomUUID() }, { officeId: randomUUID() }, { userId: 'bad' },
  { sessionId: randomUUID() }, { joinedAt: '2026-02-30T10:00:00.000Z' },
  { displayName: 'Claimed identity' },
]) {
  assert(!isOfficePresence({ ...presence, ...patch }, presenceContext))
}
console.log('PASS office Presence and Broadcast payload contracts')
