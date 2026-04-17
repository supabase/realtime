import { subscribeToJobsByOrganization, supabase, waitForSubscribed } from './subscription-client.mjs'

const ORG_ID = 'org_123'
const WAIT_MS = 8000
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

function isSchemaSetupError(error) {
  const message = String(error?.message ?? error ?? '').toLowerCase()
  return (
    message.includes('invalid schema') ||
    message.includes('schema does not exist') ||
    message.includes('relation does not exist')
  )
}

function printSchemaSetupHelp() {
  console.log('[ERROR] Database schema not found')
  console.log('')
  console.log('This demo requires the pgboss schema and job table, and pgboss must be exposed to the API.')
  console.log('')
  console.log('👉 Fix:')
  console.log('1. Open your Supabase dashboard')
  console.log('2. Confirm this project URL matches [DEBUG] SUPABASE_URL above')
  console.log('3. Go to SQL Editor and run migration.sql from this project')
  console.log('4. Go to Project Settings → API → Exposed schemas, add: pgboss')
  console.log('5. Re-run: npm start')
  console.log('')
  console.log('Quick SQL check:')
  console.log('select to_regclass(\'pgboss.job\');')
}

async function main() {
  console.log('[SETUP] Supabase Realtime JSONB Filter MRE')
  console.log('[DEBUG] SUPABASE_URL =', process.env.SUPABASE_URL)
  console.log(`[SETUP] Realtime filter used: organization_id=eq.${ORG_ID}`)

  let channel
  let eventsReceived = 0

  // Pre-check setup before subscribing/inserting.
  const { error: setupCheckError } = await supabase
    .schema('pgboss')
    .from('job')
    .select('id')
    .limit(1)

  if (setupCheckError) {
    if (isSchemaSetupError(setupCheckError)) {
      printSchemaSetupHelp()
      process.exit(1)
    }

    throw new Error(`[ERROR] Setup check failed: ${setupCheckError.message}`)
  }

  channel = subscribeToJobsByOrganization(ORG_ID, () => {
    eventsReceived += 1
  })

  await waitForSubscribed(channel, 'subscription')
  console.log('[SUBSCRIBED] Ready to receive events')

  let inserted

  try {
    console.log('[INSERT] Creating job with JSONB data: { organization_id: "org_123" }')
    const { data: insertedRows, error: insertError } = await supabase
      .schema('pgboss')
      .from('job')
      .insert({ data: { organization_id: ORG_ID } })
      .select('id, data, organization_id, created_at')

    if (insertError) throw insertError
    inserted = insertedRows?.[0]
  } catch (error) {
    if (isSchemaSetupError(error)) {
      printSchemaSetupHelp()
      process.exit(1)
    }

    throw new Error(`[ERROR] Insert failed: ${error.message}`)
  }

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

  if (channel) await supabase.removeChannel(channel)
}

main().catch((err) => {
  if (isSchemaSetupError(err)) {
    printSchemaSetupHelp()
    process.exit(1)
  }

  console.error('[ERROR]', err.message)
  process.exit(1)
})
