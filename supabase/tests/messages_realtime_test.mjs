// Local integration test. The only network target is the disposable Colima gateway.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { createClient } from '@supabase/supabase-js'

const docker = ['--context', 'colima', 'exec']
const url = 'http://127.0.0.1:54321'
function localPublicKey() {
  try {
    const status = JSON.parse(execFileSync('./node_modules/.bin/supabase', [
      '--workdir', '/tmp/virtual-workspace-local-test', 'status', '-o', 'json',
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, SUPABASE_TELEMETRY_DISABLED: '1' } }))
    assert.equal(status.API_URL, url)
    return status.PUBLISHABLE_KEY || status.ANON_KEY
  } catch {
    throw new Error('Cannot verify the local Supabase gateway configuration')
  }
}
const publicKey = localPublicKey()
assert.equal(typeof publicKey, 'string')
const a = randomUUID(), b = randomUUID()
const clients = []
const emails = []
function sql(statement) {
  return execFileSync('docker', [...docker, '-i', 'supabase_db_vw-local-baseline',
    'psql', '-XAtq', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
  { input: statement, encoding: 'utf8' }).trim()
}
async function account(label) {
  const client = createClient(url, publicKey, { auth: { persistSession: false, autoRefreshToken: false } })
  clients.push(client)
  const email = label + '-' + a + '@example.com'
  emails.push(email)
  const { data, error } = await client.auth.signUp({ email, password: randomUUID() })
  if (error || !data.session) throw new Error('Local sign-up failed for ' + label + ' (' + (error?.code ?? 'no session') + ')')
  assert.match(data.user.id, /^[a-f0-9-]{36}$/)
  return { client, id: data.user.id }
}
async function subscribe(user, workspace) {
  const events = []
  await user.client.realtime.setAuth()
  const channel = user.client.channel(randomUUID()).on('postgres_changes', {
    schema: 'public', table: 'messages', event: '*',
    ...(workspace && { filter: 'workspace_id=eq.' + workspace }),
  }, payload => events.push(payload))
  const subscription = { channel, events, user }
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Postgres Changes subscription was not ready')), 25000)
    channel.on('system', {}, signal => {
      if (signal.extension === 'postgres_changes' && signal.status === 'ok') {
        clearTimeout(timeout)
        resolve()
      }
    }).subscribe(status => {
      if (['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)) {
        clearTimeout(timeout)
        reject(new Error('Subscription ' + status))
      }
    })
  })
  return subscription
}
async function remove(sub) {
  assert.equal(await sub.user.client.removeChannel(sub.channel), 'ok')
}
async function message(user, workspace) {
  const { data, error } = await user.client.from('messages').insert({
    workspace_id: workspace, content: 'Local delivery test',
  }).select('id').single()
  if (error) throw new Error('Message insert failed: ' + error.code)
  return data.id
}
function received(sub, id, event = 'INSERT') {
  return sub.events.some(e => e.eventType === event && (e.new?.id === id || e.old?.id === id))
}
async function until(predicate) {
  const deadline = Date.now() + 15000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Expected control event was not delivered')
    await delay(50)
  }
}
try {
  const emp = await account('employee'), admin = await account('admin'), peer = await account('peer')
  const outsider = await account('outsider'), dual = await account('dual')
  sql(`begin;
    insert into public.workspaces(id,name,slug) values ('${a}','A','${a}'),('${b}','B','${b}');
    commit;`)
  for (const [user, ws, role] of [[emp,a,'employee'],[admin,a,'admin'],[peer,b,'employee'],[dual,a,'employee'],[dual,b,'employee']]) {
    assert.equal(sql(`insert into public.workspace_members(workspace_id,user_id,role)
      select '${ws}',id,'${role}' from public.users where auth_id='${user.id}' returning status;`), 'active')
  }
  const empAll = await subscribe(emp), adminAll = await subscribe(admin), peerAll = await subscribe(peer)
  const outside = await subscribe(outsider), forged = await subscribe(emp,b)
  const empA = await subscribe(emp,a)
  const first = await subscribe(dual,a)
  const a1 = await message(admin,a), b1 = await message(peer,b)
  await until(() => received(empAll,a1) && received(empA,a1) && received(first,a1) && received(peerAll,b1) && received(adminAll,a1))
  await delay(700)
  assert(!received(empAll,b1) && !received(adminAll,b1) && !received(peerAll,a1))
  assert(!received(outside,a1) && !received(outside,b1) && !received(forged,b1) && !received(first,b1))
  const activeRead = await emp.client.from('messages').select('id').eq('id',a1).single()
  assert(!activeRead.error && activeRead.data.id === a1)
  const payload = empAll.events.find(e => e.new?.id === a1).new
  assert.deepEqual(Object.keys(payload).sort(), ['channel','content','created_at','id','sender_id','workspace_id'])
  console.log('PASS R1–R5, R7, R10, R14 authenticated delivery, isolation, filter and payload')

  assert.equal(sql(`update public.workspace_members set status='removed' where workspace_id='${a}'
    and user_id=(select id from public.users where auth_id='${emp.id}') returning status;`), 'removed')
  const read = await emp.client.from('messages').select('id').eq('id',a1)
  assert(!read.error && read.data.length === 0)
  const denied = await emp.client.from('messages').insert({ workspace_id:a,content:'revocation test' })
  assert.equal(denied.error?.code,'42501')
  await remove(first)
  const second = await subscribe(dual,b)
  const a2 = await message(admin,a), b2 = await message(peer,b)
  await until(() => received(adminAll,a2) && received(second,b2))
  await delay(700)
  assert(!received(empAll,a2) && !received(empA,a2) && !received(first,a2) && !received(second,a2))
  assert.equal(empAll.channel.state,'joined')
  console.log('PASS R6, R11–R13 removal took effect on the existing subscription')
  await remove(second)
  assert(!(await dual.client.auth.signOut()).error)
  assert.equal(dual.client.getChannels().length,0)
  console.log('PASS R8/R9 explicit test-client switch and logout cleanup')

  const edit = await admin.client.from('messages').update({ content:'Edited locally' }).eq('id',a1)
  assert(!edit.error)
  await until(() => received(adminAll,a1,'UPDATE'))
  const deletion = await admin.client.from('messages').delete().eq('id',a1).select('id').single()
  assert(!deletion.error && deletion.data.id === a1)
  const barrier = await message(admin,a)
  await until(() => received(adminAll,barrier))
  await delay(700)
  for (const sub of [outside,peerAll,empAll]) {
    assert.equal(sub.channel.state,'joined')
    assert(!received(sub,a1,'UPDATE'))
  }
  assert(![outside,peerAll,empAll].some(sub => received(sub,a1,'DELETE')),
    'A delete event exposed the deleted message ID outside authorized membership')
  console.log('PASS delete-event isolation')
} finally {
  try {
    for (const client of clients) {
      await client.removeAllChannels()
      client.realtime.disconnect()
      client.auth.stopAutoRefresh()
    }
  } finally {
    sql(`begin; delete from public.workspaces where id in ('${a}','${b}');
      delete from auth.users where email in (${emails.map(e => "'" + e + "'").join(',') || 'null'}); commit;`)
  }
}
