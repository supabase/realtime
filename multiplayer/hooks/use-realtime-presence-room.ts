'use client'

import { useCurrentUserName } from '@/hooks/use-current-user-name'
import { createClient } from '@/lib/supabase/client'
import { useEffect, useState } from 'react'

const supabase = createClient()

export type RealtimeUser = {
  id: string
  name: string
  color: string
}

export const useRealtimePresenceRoom = (roomName: string, currentUserColor: string) => {
  const currentUserName = useCurrentUserName()

  const [users, setUsers] = useState<Record<string, RealtimeUser>>({})

  useEffect(() => {
    const room = supabase.channel(roomName)

    room
      .on('presence', { event: 'sync' }, () => {
        const newState = room.presenceState<{ name: string; color: string }>()

        const newUsers = Object.fromEntries(
          Object.entries(newState).map(([key, values]) => [
            key,
            { name: values[0].name, color: values[0].color },
          ])
        ) as Record<string, RealtimeUser>
        setUsers(newUsers)
      })
      .subscribe(async (status) => {
        if (status !== 'SUBSCRIBED') {
          return
        }

        await room.track({
          name: currentUserName,
          color: currentUserColor
        })
      })

    return () => {
      room.unsubscribe()
    }
  }, [roomName, currentUserName, currentUserColor])

  return { users }
}
