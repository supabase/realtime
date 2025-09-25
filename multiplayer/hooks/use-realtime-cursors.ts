import { createClient } from '@/lib/supabase/client'
import { RealtimeChannel } from '@supabase/supabase-js'
import { useCallback, useEffect, useRef, useState } from 'react'
import { nanoid } from 'nanoid'

/**
 * Throttle a callback to a certain delay, It will only call the callback if the delay has passed, with the arguments
 * from the last call
 */
const useThrottleCallback = <Params extends unknown[], Return>(
  callback: (...args: Params) => Return,
  delay: number
) => {
  const lastCall = useRef(0)
  const timeout = useRef<NodeJS.Timeout | null>(null)

  return useCallback(
    (...args: Params) => {
      const now = Date.now()
      const remainingTime = delay - (now - lastCall.current)

      if (remainingTime <= 0) {
        if (timeout.current) {
          clearTimeout(timeout.current)
          timeout.current = null
        }
        lastCall.current = now
        callback(...args)
      } else if (!timeout.current) {
        timeout.current = setTimeout(() => {
          lastCall.current = Date.now()
          timeout.current = null
          callback(...args)
        }, remainingTime)
      }
    },
    [callback, delay]
  )
}

const supabase = createClient()

const EVENT_NAME = 'realtime-cursor-move'

type CursorEventPayload = {
  position: {
    x: number
    y: number
  }
  user: {
    id: string
  }
  color: string
  timestamp: number
}

export const useRealtimeCursors = ({
  roomName,
  throttleMs,
  color
}: {
  roomName: string
  throttleMs: number
  color: string
}) => {
  const [userId] = useState(nanoid())
  const [cursors, setCursors] = useState<Record<string, CursorEventPayload>>({})

  const channelRef = useRef<RealtimeChannel | null>(null)

  const callback = useCallback(
    (event: MouseEvent) => {
      const { clientX, clientY } = event

      const payload: CursorEventPayload = {
        position: {
          x: clientX,
          y: clientY,
        },
        user: {
          id: userId
        },
        color: color,
        timestamp: new Date().getTime(),
      }

      channelRef.current?.send({
        type: 'broadcast',
        event: EVENT_NAME,
        payload: payload,
      })
    },
    [color, userId]
  )

  const handleMouseMove = useThrottleCallback(callback, throttleMs)

  useEffect(() => {
    const config = { broadcast: { ack: false, self: false }, presence: { key: userId } }
    const channel = supabase.channel(roomName, { config })
    channelRef.current = channel

    channel
      .on('presence', { event: 'leave' }, ({ leftPresences }) => {
        leftPresences.forEach(function(element) {
           // Remove cursor when user leaves
          setCursors((prev) => {
            if (prev[element.key]) {
              delete prev[element.key]
            }

            return {...prev}
          })
        })
      })
      .on('broadcast', { event: EVENT_NAME }, (data: { payload: CursorEventPayload }) => {
        const { user } = data.payload
        // Don't render your own cursor
        if (user.id === userId) return

        setCursors((prev) => {
          if (prev[userId]) {
            delete prev[userId]
          }

          return {
            ...prev,
            [user.id]: data.payload,
          }
        })
      })
    .subscribe(async (status) => {
      if (status === 'SUBSCRIBED') {
        const status = await channel.track({ key: userId, color: color })
        window.addEventListener('mousemove', handleMouseMove)
      }
    })

    return () => {
      window.removeEventListener('mousemove', handleMouseMove)
      channel.unsubscribe()
    }
  }, [])

  return { cursors }
}
