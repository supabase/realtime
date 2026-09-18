// Per-message broadcast persistence, end to end against a local Realtime server.
//
// Sends two messages on one channel. The first asks to be persisted, the second does not. Only the
// first shows up in realtime.messages.
//
// Run with: npm install && npm start

import { RealtimeClient } from '@supabase/realtime-js'
import jwt from 'jsonwebtoken'
import pg from 'pg'

const TENANT = process.env.TENANT ?? 'realtime-dev'
// Realtime resolves the tenant from the first dot-segment of the host, see
// Database.get_external_id/1. Connecting to plain localhost asks for a tenant called "localhost".
const REALTIME_URL = process.env.REALTIME_URL ?? `ws://${TENANT}.localhost:4000/socket`
// mise.toml sets API_JWT_SECRET for the dev environment.
const JWT_SECRET = process.env.API_JWT_SECRET ?? 'dev'
// `mise run example-persistence` passes this, since a non-default tenant gets a published port of
// docker's choosing.
const DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgresql://supabase_admin:postgres@localhost:5433/postgres'

// A fresh room per run, so runs do not accumulate into each other's assertions.
const TOPIC = process.env.TOPIC ?? `persisted:demo-${Date.now().toString(36)}`
const USER = '11111111-1111-1111-1111-111111111111'

const token = jwt.sign({ role: 'authenticated', sub: USER }, JWT_SECRET, {
  expiresIn: '1h',
})

// The policies authorize against the app's own membership table, so this run has to join the
// session as the human before anything it sends can be stored.
const db = new pg.Client({ connectionString: DATABASE_URL })
await db.connect()
await db.query(
  `insert into public.session_members (topic, user_id, role)
   values ($1, $2, 'human')
   on conflict (topic, user_id) do update set role = excluded.role`,
  [TOPIC, USER]
)

const client = new RealtimeClient(REALTIME_URL, {
  params: { apikey: token, vsn: '2.0.0' },
  timeout: 10_000,
})

client.setAuth(token)

const channel = client.channel(TOPIC, {
  config: { private: true, broadcast: { ack: true, self: true } },
})

const subscribed = new Promise((resolve, reject) => {
  channel.subscribe((status, err) => {
    if (status === 'SUBSCRIBED') resolve()
    if (status === 'CHANNEL_ERROR') reject(err ?? new Error('channel error'))
    if (status === 'TIMED_OUT') reject(new Error('subscribe timed out'))
  })
})

// Everything that arrives on the channel, so we can show delivery is unaffected by persistence.
const delivered = []
channel.on('broadcast', { event: 'message' }, ({ payload }) => delivered.push(payload))

await subscribed
console.log(`connected to realtime:${TOPIC}\n`)

async function send(text, persist) {
  console.log(`sending  { text: "${text}" }  persist: ${persist}`)

  // `persist` sits next to type/event/payload, not inside payload. The serializer forwards it as
  // frame metadata, so subscribers never see it.
  const result = await channel.send({
    type: 'broadcast',
    event: 'message',
    payload: { text },
    ...(persist ? { persist: true } : {}),
  })

  console.log(`  ${result}\n`)
}

await send('keep this one', true)
await send('do not keep this', false)

// Give the delivery path a moment before reading the table.
await new Promise((resolve) => setTimeout(resolve, 500))

const { rows } = await db.query(
  `select id, event, payload, extension, private, skip_broadcast
     from realtime.messages
    where topic = $1
    order by inserted_at desc`,
  [TOPIC]
)

console.log(`delivered to subscribers: ${delivered.length}`)
delivered.forEach((p) => console.log(`  ${p.text}`))

console.log(`\nrows in realtime.messages for ${TOPIC}: ${rows.length}`)
rows.forEach((r) => console.log(`  ${r.id}  ${r.payload.text}  extension=${r.extension}`))

if (rows.length !== 1) {
  console.error(`\nexpected exactly 1 stored row, got ${rows.length}`)
  process.exitCode = 1
} else if (rows[0].payload.text !== 'keep this one') {
  console.error(`\nstored the wrong message: ${rows[0].payload.text}`)
  process.exitCode = 1
} else {
  console.log('\nonly the message that asked to be persisted was stored')
}

await db.end()
client.disconnect()
