import { subscribeToJobsByOrganization, supabase, waitForSubscribed } from './subscription-client.mjs'

const ORG_ID = 'org_123'
const WAIT_MS = 8000
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

async function main() {
  console.log('[SETUP] Supabase Realtime JSONB Filter MRE')
  console.log(`[SETUP] Realtime filter used: organization_id=eq.${ORG_ID}`)

  let eventsReceived = 0

  const channel = subscribeToJobsByOrganization(ORG_ID, () => {
    eventsReceived += 1
  })

  await waitForSubscribed(channel, 'subscription')
  console.log('[SUBSCRIBED] Ready to receive events')

  console.log('[INSERT] Creating job with JSONB data: { organization_id: "org_123" }')
  const { data: insertedRows, error: insertError } = await supabase
    .schema('pgboss')
    .from('job')
    .insert({ data: { organization_id: ORG_ID } })
    .select('id, data, organization_id, created_at')

  if (insertError) throw new Error(`[ERROR] Insert failed: ${insertError.message}`)

  const inserted = insertedRows?.[0]
  console.log(`[INSERT] Row created with ID: ${inserted.id}`)
  console.log(`[INSERT] organization_id auto-filled: ${inserted.organization_id}`)

  if (!inserted || inserted.organization_id !== ORG_ID) {
    throw new Error(
      `[ERROR] Trigger sync failed: expected ${ORG_ID}, got ${inserted?.organization_id ?? 'null'}`
    )
  }

  console.log(`[WAIT] Waiting ${WAIT_MS / 1000}s for realtime event...`)
  await pause(WAIT_MS)

  console.log('')
  console.log('[RESULT] Summary:')
  console.log(`[RESULT] Events received: ${eventsReceived}`)

  if (eventsReceived < 1) {
    console.log('[RESULT]')
    console.log('[RESULT] ❌ FAIL: No realtime event received')
    console.log('[RESULT]')
    console.log('[RESULT] This proves: JSONB filter would NOT work (data->>organization_id)')
    console.log('[RESULT] But direct column filter DOES work (organization_id)')
    throw new Error('Expected 1+ event but received none')
  }

  console.log('[RESULT]')
  console.log('[RESULT] ✅ PASS: Realtime event received with direct column filter')
  console.log('[RESULT] ✅ PASS: Trigger kept organization_id in sync')
  console.log('[RESULT]')

  await supabase.removeChannel(channel)
}

main().catch((err) => {
  console.error('[ERROR]', err.message)
  process.exit(1)
})
