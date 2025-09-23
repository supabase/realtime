'use client'

import { useEffect, useState } from 'react'
import {
  REALTIME_SUBSCRIBE_STATES,
} from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/client'

const EVENT_NAME = 'ping'

const supabase = createClient()

export const useRealtimeLatencyRoom = (id : string) => {
  const [latency, setLatency] = useState<number>(0)

  useEffect(() => {
    const config = { broadcast: { ack: true } }
    const room = supabase.channel(`latency-${id}`, { config })
    let pingIntervalId: ReturnType<typeof setInterval> | undefined

    room
      .subscribe((status: `${REALTIME_SUBSCRIBE_STATES}`) => {
        if (status === REALTIME_SUBSCRIBE_STATES.SUBSCRIBED) {
          pingIntervalId = setInterval(async () => {
            const start = performance.now()
            const resp = await room.send({
              type: 'broadcast',
              event: 'PING',
              payload: {},
            })

            if (resp !== 'ok') {
              console.log('pingChannel broadcast error')
            } else {
              const end = performance.now()
              const newLatency = end - start

              setLatency(newLatency)
            }
          }, 2000)
        }
      })
  }, [])

  return { latency }
}
