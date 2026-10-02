// Browser demo for per-message broadcast persistence.
//
// The dev server signs the JWT and runs the SQL, because a browser cannot do either. Everything
// else here is the same realtime-js API an app would use.

import { RealtimeClient } from '@supabase/realtime-js'

import { identities, policyFor } from './presets.js'

import { createHighlighter } from '@lumis-sh/lumis'
import { htmlInline } from '@lumis-sh/lumis/formatters'
import javascript from '@lumis-sh/lumis/langs/javascript'
import sqlLang from '@lumis-sh/lumis/langs/sql'
import theme from '@lumis-sh/themes/vesper'

const el = (id) => document.getElementById(id)

const ui = {
  policiesSql: el('policies-sql'),
  policiesHighlight: el('policies-highlight'),
  keepAgent: el('keep-agent'),
  keepAgentNote: el('keep-agent-note'),
  checkTopic: el('check-topic'),
  checkRead: el('check-read'),
  checkBroadcast: el('check-broadcast'),
  checkHumanStore: el('check-human-store'),
  checkPersistence: el('check-persistence'),
  policiesRows: el('policies-rows'),
  policiesResult: el('policies-result'),
  policiesApply: el('policies-apply'),
  policiesDrop: el('policies-drop'),
  policiesReset: el('policies-reset'),
  statusDot: el('status-dot'),
  statusText: el('status-text'),
  topic: el('topic'),
  topicWarning: el('topic-warning'),
  replay: el('replay'),
  replayLimit: el('replay-limit'),
  connect: el('connect'),
  disconnect: el('disconnect'),
  text: el('text'),
  persist: el('persist'),
  send: el('send'),
  sendResult: el('send-result'),
  sendCode: el('send-code'),
  rejoin: el('rejoin'),
  chat: el('chat'),
  sql: el('sql'),
  dbCount: el('db-count'),
  dbRows: el('db-rows'),
  refresh: el('refresh'),
  restart: el('restart'),
  clear: el('clear'),
}

let client = null
let channel = null
let agentClient = null
let agentChannel = null
// subscribe() can fire SUBSCRIBED more than once, and a second agent would answer every prompt
// twice, from a connection that may still hold an older policy answer.
let agentJoining = false
let config = null
// A deliberate Leave closes the socket, which the channel reports as an error. Ignore it.
let leaving = false


const timeFormat = new Intl.DateTimeFormat(undefined, {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  fractionalSecondDigits: 3,
  hour12: false,
})

const formatTime = (value) => timeFormat.format(new Date(value))

const EVENT = 'message'

const HUMAN = identities.find((i) => i.key === 'human')
const AGENT = identities.find((i) => i.key === 'agent')

const currentSub = () => HUMAN.sub
const currentIdentity = () => HUMAN

// The agent's ack can land before or after the server echoes its message back to us, so remember
// the outcome by nonce and let whichever happens second fill in the badge.
const savedByNonce = new Map()

// Placeholder work, enough to look like a harness without pretending to be one.
const AGENT_REPLIES = [
  ['processing...', 'done, 3 files changed'],
  ['processing...', 'added tests, 12 passing'],
  ['processing...', 'applied the patch'],
]
let replyTurn = 0

function setStatus(state, text) {
  ui.statusDot.dataset.state = state
  ui.statusText.textContent = text
}

function joined(isJoined) {
  ui.connect.disabled = isJoined
  ui.disconnect.disabled = !isJoined
  ui.send.disabled = !isJoined
  ui.rejoin.disabled = !isJoined
  ui.topic.disabled = isJoined
  ui.replay.disabled = isJoined
  ui.replayLimit.disabled = isJoined
}

function clearChat(placeholder) {
  ui.chat.innerHTML = ''
  if (placeholder) {
    const li = document.createElement('li')
    li.dataset.empty = ''
    li.className = 'p-4 text-center text-neutral-500'
    li.textContent = placeholder
    ui.chat.append(li)
  }
}

// `state` is 'history', true, false, or undefined while the ack is still in flight.
function setTag(tag, state) {
  const [label, classes] =
    state === 'history'
      ? ['from history', 'bg-amber-400/15 text-amber-400']
      : state === true
        ? ['saved', 'bg-emerald-400/15 text-emerald-400']
        : state === false
          ? ['not saved', 'bg-neutral-700/40 text-neutral-400']
          : ['saving', 'bg-neutral-700/40 text-neutral-500']

  tag.className = `rounded px-1.5 py-0.5 font-mono text-[10px] tracking-wider uppercase ${classes}`
  tag.textContent = label
}

// The server echoes our message back before it replies, so the bubble renders first and the ack
// fills in whether it was kept.
function markSaved(nonce, saved) {
  savedByNonce.set(nonce, saved)
  const tag = ui.chat.querySelector(`[data-nonce="${nonce}"] [data-tag]`)
  if (tag) setTag(tag, saved)
}

function addMessage({ text, from, replayed, saved, nonce }) {
  ui.chat.querySelector('[data-empty]')?.remove()

  const li = document.createElement('li')
  li.className =
    'flex items-baseline gap-2.5 rounded px-2 py-1.5 not-first:border-t not-first:border-neutral-800'

  const time = document.createElement('time')
  time.className = 'font-mono text-[11px] text-neutral-500 tabular-nums'
  time.textContent = formatTime(Date.now())

  const author = document.createElement('span')
  const isAgent = from === 'agent'
  author.className = `w-16 shrink-0 truncate text-xs font-semibold ${
    isAgent ? 'text-sky-400' : 'text-neutral-300'
  }`
  author.textContent = isAgent ? 'Agent' : from === 'human' ? 'You' : ''

  const body = document.createElement('span')
  body.className = 'flex-1'
  body.textContent = text

  // Kept or not is the whole point, so every message says which.
  const tag = document.createElement('span')
  setTag(tag, replayed ? 'history' : (savedByNonce.get(nonce) ?? saved))

  tag.dataset.tag = ''
  if (nonce) li.dataset.nonce = nonce

  li.append(time, author, body, tag)
  ui.chat.append(li)
  ui.chat.scrollTop = ui.chat.scrollHeight
}

// Created once at boot. Until then the blocks render as plain text.
let highlighter = null

// Lumis escapes the code it highlights, so user input in these snippets is safe to inject.
function renderCode(target, code, language) {
  if (!highlighter) {
    target.textContent = code
    return
  }

  target.innerHTML = highlighter.highlight(code, htmlInline({ language, theme }))
}

// Shows the exact call the buttons are making, so the page doubles as documentation.
function showSendCode() {
  const persist = ui.persist.checked

  renderCode(
    ui.sendCode,
    `await channel.send({
  type: 'broadcast',
  event: '${EVENT}',
  payload: { text: '${ui.text.value}', from: '${currentIdentity()?.key ?? ''}' },${persist ? "\n  persist: true," : ''}
})`,
    javascript
  )
}

// The editor's highlighted backdrop. A trailing newline keeps the last line from being clipped
// while typing at the end.
function showPoliciesCode() {
  renderCode(ui.policiesHighlight, `${ui.policiesSql.value}\n`, sqlLang)
  syncPoliciesScroll()
}

function syncPoliciesScroll() {
  const pre = ui.policiesHighlight.querySelector('pre')
  if (!pre) return
  pre.scrollTop = ui.policiesSql.scrollTop
  pre.scrollLeft = ui.policiesSql.scrollLeft
}

function showSql(topic) {
  renderCode(
    ui.sql,
    `select inserted_at,
       payload ->> 'from' as author,
       payload ->> 'text' as message,
       id
from realtime.messages
where topic = '${topic}'
order by inserted_at desc;`,
    sqlLang
  )
}

// Which extension a policy targets is the whole point of the demo, and it is buried in the
// WITH CHECK expression, so pull it out for the table.
function policyExtension(row) {
  const match = `${row.with_check ?? ''} ${row.qual ?? ''}`.match(
    /extension\s*=\s*'?([a-z_]+)'?/i
  )
  return match?.[1] ?? (row.cmd === 'SELECT' ? 'read' : 'any')
}

async function refreshPolicies() {
  const { rows, error } = await (await fetch('/api/policies')).json()

  ui.policiesRows.innerHTML = ''

  if (error) {
    ui.policiesResult.textContent = error
    ui.policiesResult.dataset.state = 'error'
    return
  }

  if (!rows.length) {
    const tr = document.createElement('tr')
    const td = document.createElement('td')
    td.colSpan = 3
    td.className = 'px-2 py-2 text-neutral-500'
    td.textContent = 'No policies. Nothing can send, store, or read.'
    tr.append(td)
    ui.policiesRows.append(tr)
    return
  }

  for (const row of rows) {
    const tr = document.createElement('tr')

    for (const value of [row.policyname, row.cmd, policyExtension(row)]) {
      const td = document.createElement('td')
      td.className = 'border-b border-neutral-800 px-2 py-1 text-neutral-300'
      td.textContent = value
      tr.append(td)
    }

    ui.policiesRows.append(tr)
  }
}

// Asks the database what the current policies would answer for this topic, without joining.
async function refreshCheck() {
  const topic = ui.topic.value
  ui.checkTopic.textContent = topic

  const ask = (sub) =>
    fetch(
      `/api/check?topic=${encodeURIComponent(topic)}&sub=${encodeURIComponent(sub)}`
    ).then((r) => r.json())

  const [human, agent] = await Promise.all([ask(HUMAN.sub), ask(AGENT.sub)])

  // Join and send are the same for both. Storing is the one that differs, so show it per party.
  for (const [state, node, label] of [
    [human.read, ui.checkRead, 'join'],
    [human.broadcast, ui.checkBroadcast, 'send'],
    [human.persistence, ui.checkHumanStore, 'store you'],
    [agent.persistence, ui.checkPersistence, 'store agent'],
  ]) {
    node.textContent = `${label} ${state ?? 'unknown'}`
    if (state === 'allowed' || state === 'denied') node.dataset.state = state
    else delete node.dataset.state
  }

  return { human, agent }
}

// The checkbox is the decision: prompts only, or the whole transcript. Toggling rewrites the
// persistence policy and applies it, so the page always shows the SQL that is actually in force.
async function applyKeepAgent() {
  const keepAgent = ui.keepAgent.checked

  ui.keepAgentNote.textContent = keepAgent
    ? 'Every message is kept, yours and the agent\'s.'
    : 'Only your prompts are kept. The agent still talks, nothing it says is stored.'

  ui.policiesSql.value = policyFor(keepAgent)
  showPoliciesCode()
  await runPolicies('POST', { sql: ui.policiesSql.value })

  // Both channels cached their answer on join, so a live session has to rejoin to see the change.
  if (channel) {
    leave()
    clearChat('Reconnecting with the new policy')
    await join()
  }
}

async function runPolicies(method, body) {
  ui.policiesResult.textContent = 'Running'
  delete ui.policiesResult.dataset.state

  const response = await fetch('/api/policies', {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  })

  const { error } = await response.json()

  ui.policiesResult.textContent = error ?? (method === 'DELETE' ? 'Policies dropped.' : 'SQL ran.')
  ui.policiesResult.dataset.state = error ? 'error' : 'ok'

  await refreshPolicies()
  await refreshCheck()
}

async function refreshRows() {
  const topic = ui.topic.value
  showSql(topic)

  const response = await fetch(`/api/stored?topic=${encodeURIComponent(topic)}`)
  const { rows, error } = await response.json()

  if (error) {
    ui.dbCount.textContent = `Query failed: ${error}`
    return
  }

  ui.dbRows.innerHTML = ''
  ui.dbCount.textContent = rows.length === 1 ? '1 row stored.' : `${rows.length} rows stored.`

  for (const row of rows) {
    const tr = document.createElement('tr')
    // Same columns the query above selects, in the same order.
    const cells = [
      formatTime(row.inserted_at),
      row.payload?.from ?? '',
      row.payload?.text ?? '',
      `${row.id.slice(0, 8)}...`,
    ]

    for (const value of cells) {
      const td = document.createElement('td')
      td.className = 'border-b border-neutral-800 px-2 py-1 text-neutral-300'
      td.textContent = value
      tr.append(td)
    }

    ui.dbRows.append(tr)
  }
}

async function join() {
  const topic = ui.topic.value
  leaving = false
  setStatus('connecting', 'Joining')
  clearChat(null)

  const { token } = await (await fetch(`/api/token?sub=${encodeURIComponent(currentSub())}`)).json()

  client = new RealtimeClient(config.realtimeUrl, {
    params: { apikey: token, vsn: '2.0.0' },
    timeout: 10_000,
  })
  client.setAuth(token)

  const broadcast = { self: true, ack: true }

  // `replay` asks the server to read the table on join and push the history back first.
  if (ui.replay.checked) {
    broadcast.replay = { limit: Number(ui.replayLimit.value), since: 0 }
  }

  channel = client.channel(topic, { config: { private: true, broadcast } })

  channel.on('broadcast', { event: '*' }, ({ event, payload, meta }) => {
    addMessage({
      text: payload?.text ?? JSON.stringify(payload),
      event,
      from: payload?.from,
      nonce: payload?.nonce,
      replayed: meta?.replayed === true,
      saved: meta?.replayed === true ? true : undefined,
    })
  })

  channel.subscribe((status, err) => {
    if (status === 'SUBSCRIBED') {
      setStatus('open', `Joined ${topic}`)
      joined(true)
      if (!ui.chat.children.length) clearChat('No history yet. Send a prompt.')
      refreshRows()
      joinAgent(topic)
    }

    if (status === 'CHANNEL_ERROR') {
      if (leaving) return
      setStatus('error', `Error: ${err?.message ?? 'channel error'}`)
      joined(false)
    }

    if (status === 'TIMED_OUT') {
      if (leaving) return
      setStatus('error', 'Join timed out')
      joined(false)
    }

    if (status === 'CLOSED') {
      setStatus('closed', 'Not connected')
      joined(false)
    }
  })
}

// The agent is a second client on the same channel, exactly as a real harness process would be.
// `self: false` so it does not react to its own replies, and no replay so it does not re-answer
// history on reconnect.
async function joinAgent(topic) {
  if (agentJoining || agentClient) return
  agentJoining = true

  const { token } = await (await fetch(`/api/token?sub=${encodeURIComponent(AGENT.sub)}`)).json()

  agentClient = new RealtimeClient(config.realtimeUrl, {
    params: { apikey: token, vsn: '2.0.0' },
    timeout: 10_000,
  })
  agentClient.setAuth(token)

  agentChannel = agentClient.channel(topic, {
    config: { private: true, broadcast: { self: false, ack: true } },
  })

  agentChannel.on('broadcast', { event: '*' }, ({ payload, meta }) => {
    if (meta?.replayed || payload?.from !== 'human') return
    respond()
  })

  await new Promise((resolve) => {
    agentChannel.subscribe((status) => {
      if (status === 'SUBSCRIBED' || status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') resolve()
    })
  })

  agentJoining = false
}

async function respond() {
  const replies = AGENT_REPLIES[replyTurn++ % AGENT_REPLIES.length]

  for (const [index, text] of replies.entries()) {
    await new Promise((r) => setTimeout(r, index === 0 ? 350 : 900))
    if (!agentChannel) return

    const nonce = crypto.randomUUID()

    // A harness always asks to keep its output. Whether it is kept is the policy's call.
    const { id } = await sendWithAck(agentChannel, {
      type: 'broadcast',
      event: EVENT,
      payload: { text, from: 'agent', nonce },
      persist: true,
    })

    markSaved(nonce, Boolean(id))
    await refreshRows()
  }
}

function leave() {
  leaving = true
  client?.disconnect()
  agentClient?.disconnect()
  client = null
  channel = null
  agentClient = null
  agentChannel = null
  agentJoining = false
  joined(false)
  setStatus('closed', 'Not connected')
}

ui.connect.addEventListener('click', join)

ui.disconnect.addEventListener('click', () => {
  leave()
  clearChat('Left the channel.')
})

ui.rejoin.addEventListener('click', async () => {
  leave()
  clearChat('Reconnecting')
  await join()
})

// With `ack: true` the server replies with the stored row's id, and writes the row before replying
// instead of in a background task. `channel.send()` resolves with only 'ok', so it drops that
// payload; pushing through the adapter keeps it.
function sendWithAck(target, args, timeout = 10_000) {
  return new Promise((resolve) => {
    target.channelAdapter
      .push('broadcast', args, timeout)
      .receive('ok', (reply) => resolve({ status: 'ok', id: reply?.id }))
      .receive('error', (reply) => resolve({ status: 'error', reply }))
      .receive('timeout', () => resolve({ status: 'timed out' }))
  })
}

ui.send.addEventListener('click', async () => {
  const persist = ui.persist.checked
  const nonce = crypto.randomUUID()

  const { status, id } = await sendWithAck(channel, {
    type: 'broadcast',
    event: EVENT,
    payload: { text: ui.text.value, from: currentIdentity()?.key, nonce },
    ...(persist ? { persist: true } : {}),
  })

  markSaved(nonce, Boolean(id))

  ui.sendResult.textContent = id
    ? `ack: ${status}, saved as ${id}`
    : persist
      ? `ack: ${status}, not saved. Retention does not cover ${currentIdentity()?.name ?? 'you'}.`
      : `ack: ${status}, not saved. You did not ask to.`
  ui.sendResult.dataset.state = status === 'ok' ? 'ok' : 'error'

  await refreshRows()
})

ui.policiesApply.addEventListener('click', () => runPolicies('POST', { sql: ui.policiesSql.value }))
ui.policiesDrop.addEventListener('click', () => runPolicies('DELETE'))

ui.policiesReset.addEventListener('click', () => {
  ui.policiesSql.value = policyFor(ui.keepAgent.checked)
  showPoliciesCode()
  ui.policiesResult.textContent = 'Reset. Not run yet.'
  delete ui.policiesResult.dataset.state
})

ui.keepAgent.addEventListener('change', applyKeepAgent)

// Back to the state a fresh checkout starts in: no rows, policies exactly as policies.sql says.
ui.restart.addEventListener('click', async () => {
  ui.restart.disabled = true
  ui.restart.textContent = 'Restarting'

  leave()
  clearChat('Restarted. Join to start a new session.')

  const { error } = await (await fetch('/api/restart', { method: 'POST' })).json()

  ui.keepAgent.checked = false
  ui.topic.value = 'persisted:session-1'
  ui.policiesSql.value = policyFor(false)
  ui.keepAgentNote.textContent =
    'Only your prompts are kept. The agent still talks, nothing it says is stored.'
  ui.sendResult.textContent = ''
  delete ui.sendResult.dataset.state
  ui.policiesResult.textContent = error ?? 'Everything reset.'
  ui.policiesResult.dataset.state = error ? 'error' : 'ok'

  showPoliciesCode()
  showSql(ui.topic.value)
  await refreshPolicies()
  await refreshCheck()
  await refreshRows()

  ui.restart.disabled = false
  ui.restart.textContent = 'Restart demo'
})

ui.policiesSql.addEventListener('input', showPoliciesCode)
ui.policiesSql.addEventListener('scroll', syncPoliciesScroll)

ui.refresh.addEventListener('click', refreshRows)

ui.clear.addEventListener('click', async () => {
  await fetch(`/api/stored?topic=${encodeURIComponent(ui.topic.value)}`, { method: 'DELETE' })
  await refreshRows()
})

ui.topic.addEventListener('input', () => {
  ui.topicWarning.hidden = ui.topic.value.startsWith('persisted:')
  showSql(ui.topic.value)
  refreshCheck()
})

// Rejoining without replay just gives you an empty channel, so say what the button will do.
function showRejoinIntent() {
  const willReplay = ui.replay.checked
  ui.rejoin.textContent = willReplay ? 'Reconnect and replay' : 'Reconnect, no replay'
  ui.rejoin.title = willReplay
    ? 'Drops the channel and asks the server for history'
    : 'Replay history on join is off, so the channel comes back empty'
}

ui.replay.addEventListener('change', showRejoinIntent)

// Switching identity changes every answer, so re-evaluate.

for (const input of [ui.text, ui.persist]) {
  input.addEventListener('input', showSendCode)
}

// Enter sends, like any chat box.
ui.text.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !ui.send.disabled) ui.send.click()
})

config = await (await fetch('/api/config')).json()
setStatus('closed', `Not connected to ${config.tenant}`)
showRejoinIntent()
ui.policiesSql.value = policyFor(ui.keepAgent.checked)
ui.keepAgentNote.textContent =
  'Only your prompts are kept. The agent still talks, nothing it says is stored.'
await refreshPolicies()
await refreshCheck()
await refreshRows()

highlighter = await createHighlighter({ languages: [javascript, sqlLang] })
showSendCode()
showSql(ui.topic.value)
showPoliciesCode()
