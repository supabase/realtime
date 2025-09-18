'use client'

import { AvatarStack } from '@/components/avatar-stack'
import { useRealtimePresenceRoom } from '@/hooks/use-realtime-presence-room'
import { useMemo } from 'react'

export const RealtimeAvatarStack = ({ roomName }: { roomName: string }) => {
  const { users: usersMap } = useRealtimePresenceRoom(roomName)
  const avatars = useMemo(() => {
    return Object.values(usersMap).map((user) => ({
      name: user.name,
      color: user.color
    }))
  }, [usersMap])

  return <AvatarStack avatars={avatars} />
}
