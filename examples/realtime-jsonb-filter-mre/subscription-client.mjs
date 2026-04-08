import 'dotenv/config'
import { createClient } from '@supabase/supabase-js'

const supabaseUrl = process.env.SUPABASE_URL
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing SUPABASE_URL or SUPABASE_ANON_KEY')
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey)

/**
 * Subscribe to jobs by organization using Realtime filters.
 *
 * Note: Realtime does not support JSONB expression filters like `data->>organization_id=eq.value`.
 * We use a dedicated scalar `organization_id` column instead, kept in sync via database trigger.
 */
export function subscribeToJobsByOrganization(organizationId, onPayload) {
  const filter = `organization_id=eq.${organizationId}`

  const channel = supabase
    .channel(`jobs-org-${organizationId}`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'pgboss',
        table: 'job',
        filter
      },
      (payload) => {
        console.log('[subscription] event received:', JSON.stringify(payload, null, 2))
        onPayload?.(payload)
      }
    )

  return channel
}

export function waitForSubscribed(channel, label = 'channel') {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`${label} subscribe timeout`)), 15000)

    channel.subscribe((status) => {
      console.log(`[${label}] status:`, status)
      if (status === 'SUBSCRIBED') {
        clearTimeout(timeout)
        resolve()
      }
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        clearTimeout(timeout)
        reject(new Error(`${label} failed with status ${status}`))
      }
    })
  })
}
