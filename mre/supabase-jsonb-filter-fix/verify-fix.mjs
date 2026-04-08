import { subscribeToJobsByOrganization, supabase, waitForSubscribed } from './subscription-client.mjs'

// Realtime filters work on direct columns, not JSONB path expressions.
// We insert JSONB data and rely on the DB trigger to mirror organization_id to a scalar column.
const ORG_ID = 'org_123'
const WAIT_MS = 8000
const pause = (ms) => new Promise((r) => setTimeout(r, ms))

async function main() {
  console.log('--- Verify Supabase Realtime JSONB filter fix ---')
  console.log(`Filter used: organization_id=eq.${ORG_ID}`)

  let eventsReceived = 0

  const channel = subscribeToJobsByOrganization(ORG_ID, () => {
    eventsReceived += 1
  })

  await waitForSubscribed(channel, 'jobs subscription')

  // Insert JSONB-only organization_id. Trigger should auto-populate scalar organization_id.
  const { data: insertedRows, error: insertError } = await supabase
    .schema('pgboss')
    .from('job')
    .insert({ data: { organization_id: ORG_ID } })
    .select('id, data, organization_id, created_at')

  if (insertError) throw new Error(`Insert failed: ${insertError.message}`)

  const inserted = insertedRows?.[0]
  console.log('\nInserted row:')
  console.log(JSON.stringify(inserted, null, 2))

  if (!inserted || inserted.organization_id !== ORG_ID) {
    throw new Error(
      `organization_id sync failed: expected ${ORG_ID}, got ${inserted?.organization_id ?? 'null'}`
    )
  }

  console.log('\n✅ organization_id auto-fill check passed')

  console.log(`\nWaiting ${WAIT_MS / 1000}s for realtime event...`)
  await pause(WAIT_MS)

  console.log('\nResult summary:')
  console.log(`- Realtime events received: ${eventsReceived}`)

  if (eventsReceived < 1) {
    throw new Error('No realtime event received for organization_id filtered subscription')
  }

  console.log('✅ Realtime filtered subscription works')

  await supabase.removeChannel(channel)
}

main().catch((err) => {
  console.error('\nFailure:', err.message)
  process.exit(1)
})
