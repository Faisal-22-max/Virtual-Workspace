// Integration against the fresh disposable Colima stack only.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { createClient } from '@supabase/supabase-js'

const workdir = process.argv[2]
assert.match(workdir ?? '', /^\/tmp\/virtual-workspace-local-test\/office-fresh\.[a-zA-Z0-9]+$/)
const url = 'http://127.0.0.1:54421'
let publicKey
try {
  const status = JSON.parse(execFileSync(process.env.VW_SUPABASE_CLI ?? './node_modules/.bin/supabase', [
    '--workdir', workdir, 'status', '-o', 'json',
  ], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, SUPABASE_TELEMETRY_DISABLED: '1' },
  }))
  assert.equal(status.API_URL, url)
  publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY
} catch {
  throw new Error('Cannot verify the fresh local Supabase gateway')
}
assert.equal(typeof publicKey, 'string')

const a = randomUUID()
const b = randomUUID()
const clients = []
const emails = []

function sql(statement) {
  return execFileSync('docker', ['--context', 'colima', 'exec', '-i', 'supabase_db_vw-office-fresh',
    'psql', '-XAtq', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
  { input: statement, encoding: 'utf8' }).trim()
}

function createLocalClient() {
  const client = createClient(url, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  clients.push(client)
  return client
}

async function account(label) {
  const client = createLocalClient()
  const email = `${label}-${a}@example.com`
  emails.push(email)
  const { data, error } = await client.auth.signUp({
    email, password: randomUUID(), options: { data: { name: label } },
  })
  assert(data?.session, `Local sign-up failed for ${label} (${error?.code ?? 'no session'})`)
  return { client, session: data.session, authId: data.user.id }
}

async function until(predicate, description, timeout = 12000) {
  const deadline = Date.now() + timeout
  while (!predicate()) {
    assert(Date.now() < deadline, description)
    await delay(50)
  }
}

async function join(client, topic, isPrivate = true, sessionId = randomUUID()) {
  await client.realtime.setAuth()
  const received = []
  const statuses = []
  let denied = false
  const channel = client.channel(topic, {
    config: { private: isPrivate, presence: { key: sessionId }, broadcast: { ack: true, self: false } },
  })
  channel.on('presence', { event: 'sync' }, () => {})
  for (const event of ['player_moved', 'player_stopped', 'office_layout_updated']) {
    channel.on('broadcast', { event }, ({ payload }) => received.push({ event, payload }))
  }
  channel.subscribe((status, error) => {
    if (statuses.length === 0) {
      denied = /do not have permissions|unauthorized|forbidden/i.test(error?.message ?? '')
    }
    statuses.push(status)
  })
  await until(() => statuses.length > 0, 'Realtime join did not report a status')
  return { channel, sessionId, received, statuses, status: statuses[0], denied }
}

async function expectDenied(client, topic) {
  const result = await join(client, topic)
  assert(result.status === 'CHANNEL_ERROR' && result.denied,
    'A private join must receive an explicit server authorization denial')
  await client.removeChannel(result.channel)
}

async function newTab(session) {
  const client = createLocalClient()
  const { error } = await client.auth.setSession({
    access_token: session.access_token, refresh_token: session.refresh_token,
  })
  assert(!error, 'Could not restore a local Auth session')
  return client
}

function move(sender, officeId, sequence, event = 'player_moved') {
  return sender.channel.send({
    type: 'broadcast', event,
    payload: { officeId, sessionId: sender.sessionId, x: 0.3, y: 0.4, direction: 'down', sequence },
  })
}

function saw(receiver, sender, sequence, event = 'player_moved') {
  return receiver.received.some(packet => packet.event === event
    && packet.payload.sessionId === sender.sessionId && packet.payload.sequence === sequence)
}

function track(sender, userId, officeId) {
  return sender.channel.track({ userId, officeId, workspaceId: a, sessionId: sender.sessionId,
    joinedAt: new Date().toISOString() })
}

try {
  const admin = await account('admin')
  const employee = await account('employee')
  const outsider = await account('outsider')
  const anonymous = createLocalClient()
  sql(`begin;
    insert into public.workspaces (id, name, slug) values ('${a}','A','${a}'),('${b}','B','${b}');
    insert into public.workspace_members (user_id, workspace_id, role)
    select id, '${a}', case when auth_id = '${admin.authId}' then 'admin' else 'employee' end
    from public.users where auth_id in ('${admin.authId}', '${employee.authId}');
    insert into public.workspace_members (user_id, workspace_id, role)
    select id, '${b}', 'admin' from public.users where auth_id = '${outsider.authId}';
    commit;`)
  const { data: office, error: officeError } = await employee.client.from('offices')
    .select('id, workspace_id, map_version').eq('workspace_id', a).single()
  assert(!officeError && office?.workspace_id === a)
  const { data: employeeProfile, error: profileError } = await employee.client.from('users')
    .select('id').eq('auth_id', employee.authId).single()
  assert(!profileError && employeeProfile?.id)
  const { data: roster, error: rosterError } = await employee.client.from('workspace_members')
    .select('user_id, profile:users!workspace_members_user_id_fkey(id, display_name, name)')
    .eq('workspace_id', a).eq('status', 'active')
  assert(!rosterError)
  assert.deepEqual(roster.map(member => member.profile.name).sort(), ['admin', 'employee'])

  const topic = `office:${a}`
  const adminJoin = await join(admin.client, topic)
  const employeeJoin = await join(employee.client, topic)
  assert.equal(adminJoin.status, 'SUBSCRIBED')
  assert.equal(employeeJoin.status, 'SUBSCRIBED')
  await expectDenied(outsider.client, topic)
  await expectDenied(anonymous, topic)
  await expectDenied(employee.client, `office:${b}`)
  await expectDenied(employee.client, `${topic}:extra`)
  await expectDenied(employee.client, 'office:not-a-uuid')
  const outsiderOwn = await join(outsider.client, `office:${b}`)
  assert.equal(outsiderOwn.status, 'SUBSCRIBED')

  assert.equal(await track(employeeJoin, employeeProfile.id, office.id), 'ok')
  await until(() => adminJoin.channel.presenceState()[employeeJoin.sessionId]?.length === 1,
    'Employee Presence was not delivered')
  assert.equal(await move(employeeJoin, office.id, 0), 'ok')
  await until(() => saw(adminJoin, employeeJoin, 0), 'Employee Broadcast was not delivered')
  assert(!saw(outsiderOwn, employeeJoin, 0))
  assert(!outsiderOwn.channel.presenceState()[employeeJoin.sessionId])
  assert.equal(await move(employeeJoin, office.id, 2, 'player_stopped'), 'ok')
  await until(() => saw(adminJoin, employeeJoin, 2, 'player_stopped'), 'Stop event was not delivered')

  const { data: layout, error: layoutError } = await admin.client.from('offices')
    .update({ map_config: { rooms: [] } })
    .eq('id', office.id).eq('map_version', office.map_version).select('map_version').single()
  assert(!layoutError && layout?.map_version === office.map_version + 1)
  assert.equal(await adminJoin.channel.send({
    type: 'broadcast', event: 'office_layout_updated',
    payload: { officeId: office.id, mapVersion: layout.map_version },
  }), 'ok')
  await until(() => employeeJoin.received.some(packet => packet.event === 'office_layout_updated'
    && packet.payload.officeId === office.id && packet.payload.mapVersion === layout.map_version),
  'Layout hint was not delivered')

  // When public channels are enabled, a public namesake must be isolated.
  const publicJoin = await join(anonymous, topic, false)
  if (publicJoin.status === 'SUBSCRIBED') {
    assert.equal(await move(publicJoin, office.id, 0), 'ok')
    assert.equal(await track(publicJoin, employeeProfile.id, office.id), 'ok')
    assert.equal(await move(employeeJoin, office.id, 3), 'ok')
    await until(() => saw(adminJoin, employeeJoin, 3), 'Private control broadcast was not delivered')
    assert(!saw(adminJoin, publicJoin, 0) && !saw(publicJoin, employeeJoin, 3))
    assert(!adminJoin.channel.presenceState()[publicJoin.sessionId])
    assert(!publicJoin.channel.presenceState()[employeeJoin.sessionId])
  } else {
    assert.equal(publicJoin.status, 'CHANNEL_ERROR')
  }

  const secondTab = await newTab(employee.session)
  const secondJoin = await join(secondTab, topic)
  assert.equal(secondJoin.status, 'SUBSCRIBED')
  assert.equal(await track(secondJoin, employeeProfile.id, office.id), 'ok')
  await until(() => adminJoin.channel.presenceState()[secondJoin.sessionId]?.length === 1,
    'Second tab Presence was not delivered')
  assert.equal(adminJoin.channel.presenceState()[employeeJoin.sessionId]?.length, 1)
  await secondTab.removeChannel(secondJoin.channel)
  await until(() => !adminJoin.channel.presenceState()[secondJoin.sessionId],
    'Closed tab stayed in Presence')

  employee.client.realtime.disconnect()
  await until(() => !adminJoin.channel.presenceState()[employeeJoin.sessionId],
    'Disconnected Presence stayed in the office')
  const replacement = await newTab(employee.session)
  const session = await join(replacement, topic, true, employeeJoin.sessionId)
  assert.equal(session.status, 'SUBSCRIBED')
  assert.equal(await track(session, employeeProfile.id, office.id), 'ok')
  await until(() => adminJoin.channel.presenceState()[session.sessionId]?.length === 1,
    'Reconnected Presence was not delivered')

  assert.equal(sql(`
    update public.workspace_members set status = 'removed'
    where workspace_id = '${a}' and user_id = '${employeeProfile.id}' returning status;
  `), 'removed')
  const removedTab = await newTab(employee.session)
  await expectDenied(removedTab, topic)

  const afterRemoval = await employee.client.from('offices').select('id').eq('workspace_id', a)
  assert(!afterRemoval.error && afterRemoval.data?.length === 0)
  assert.equal(await move(adminJoin, office.id, 2), 'ok')
  await until(() => saw(session, adminJoin, 2), 'Expected existing-channel authorization cache')
  await delay(1100)
  const refreshed = await replacement.auth.refreshSession()
  assert(refreshed.data.session?.access_token && !refreshed.error)
  assert(refreshed.data.session.access_token !== employee.session.access_token,
    'Auth refresh did not issue a different local token')
  await replacement.realtime.setAuth(refreshed.data.session.access_token)
  await until(() => session.statuses.includes('CLOSED') || session.statuses.includes('CHANNEL_ERROR'),
    'Revoked channel was not closed or rejected on token refresh')
  await until(() => !adminJoin.channel.presenceState()[session.sessionId],
    'Revoked connection Presence was not cleaned up after token refresh')
  console.log('PASS private join, tenant isolation, Broadcast, Presence, reconnect, and revocation/JWT refresh')
} finally {
  try {
    await Promise.all(clients.map(async client => {
      await client.removeAllChannels()
      client.realtime.disconnect()
      client.auth.stopAutoRefresh()
    }))
  } finally {
    sql(`begin; delete from public.workspaces where id in ('${a}', '${b}');
      delete from auth.users where email in (${emails.map(email => `'${email}'`).join(',') || 'null'}); commit;`)
  }
}
