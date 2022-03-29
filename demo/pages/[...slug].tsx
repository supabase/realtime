import type { NextPage } from 'next'
import randomColor from 'randomcolor'
import { useEffect, useState } from 'react'
import { useRouter } from 'next/router'
import { nanoid } from 'nanoid'
import cloneDeep from 'lodash.clonedeep'

import { Message } from '../types/main.type'
import Loader from '../components/Loader'
import Users from '../components/Users'
import Cursor from '../components/Cursor'
import Chatbox from '../components/Chatbox'
import WaitlistPopover from '../components/WaitlistPopover'
import { supabaseClient, realtimeClient } from '../client/SupabaseClient'
import { PostgrestResponse } from '@supabase/supabase-js'
import { RealtimeSubscriptionV2 } from '../client/RealtimeClient'

const userId = nanoid()

const Room: NextPage = () => {
  const router = useRouter()
  const { slug } = router.query
  const roomId = slug && slug[0]

  const [channel, setChannel] = useState<RealtimeSubscriptionV2>()
  const [isStateSynced, setIsStateSynced] = useState<boolean>(false)
  const [verifiedRoomId, setVerifiedRoomId] = useState<string>()

  const [users, setUsers] = useState<{
    [key: string]: { x: null | number; y: null | number; color: string }
  }>({})
  const [messages, setMessages] = useState<Message[]>([])
  const [roomChannel, setRoomChannel] = useState<RealtimeSubscriptionV2>()

  // Initialize realtime session
  useEffect(() => {
    realtimeClient.connect()

    const channel = realtimeClient.channel('room:*')
    channel.on(
      'presence',
      () => {
        setIsStateSynced(true)
      },
      { event: 'SYNC' }
    )
    channel.subscribe()

    setChannel(channel)

    return () => {
      channel.unsubscribe()
      realtimeClient.remove(channel)
      realtimeClient.disconnect()
    }
  }, [])

  // Determine if current room is verified or not
  useEffect(() => {
    if (!channel || !isStateSynced || !roomId) return

    const state = channel?.presence.state
    const presences = state[roomId]

    if (presences?.length < 5) {
      setVerifiedRoomId(roomId)
    } else if (Object.keys(state).length) {
      const rooms = Object.entries(state).map(([roomId, users]) => {
        if (Array.isArray(users)) {
          return [roomId, users.length]
        } else {
          return [roomId, undefined]
        }
      })
      const sortedRooms = rooms.sort((a: any, b: any) => a[1] - b[1])
      const [existingRoomId, roomCount] = sortedRooms[0] as [string, number]

      if (roomCount < 5) {
        setVerifiedRoomId(existingRoomId)
      } else {
        setVerifiedRoomId(nanoid())
      }
    } else {
      setVerifiedRoomId(nanoid())
    }
  }, [channel, isStateSynced, roomId])

  // Handle redirect to a verified room with enough seats
  useEffect(() => {
    if (!channel || !verifiedRoomId) return

    channel
      ?.send({
        type: 'presence',
        event: 'TRACK',
        key: verifiedRoomId,
        payload: { user_id: userId },
      })
      .then(() => {
        if (roomId !== verifiedRoomId) {
          router.push(`/${verifiedRoomId}`)
        }
      })
  }, [channel, router, roomId, verifiedRoomId])

  // Handle presence of users within the room
  useEffect(() => {
    if (!channel || !verifiedRoomId) return

    channel.on(
      'presence',
      () => {
        const state = channel.presence.state
        const roomPresences = state[verifiedRoomId] as any[]

        if (roomPresences) {
          setUsers((prevUsers) => {
            return roomPresences.reduce((acc, presence) => {
              const userId = presence.user_id
              acc[userId] = cloneDeep(prevUsers[userId]) || {
                x: null,
                y: null,
                color: randomColor(),
              }
              return acc
            }, {})
          })
        }
      },
      { event: 'SYNC' }
    )
    channel.on(
      'broadcast',
      (payload: any) =>
        setUsers((users) => {
          const usersClone = cloneDeep(users)
          const userId = payload.payload.user_id
          usersClone[userId] = {
            ...usersClone[userId],
            ...{ x: payload.payload.x, y: payload.payload.y },
          }
          return usersClone
        }),
      { event: 'POS' }
    )
  }, [channel, verifiedRoomId])

  // Load messages of the room for the chatbox
  useEffect(() => {
    if (!verifiedRoomId) return

    supabaseClient
      .from('messages')
      .select('id, user_id, message')
      .filter('room_id', 'eq', verifiedRoomId)
      .order('created_at', { ascending: false })
      .limit(10)
      .then((resp: PostgrestResponse<Message>) => resp.data && setMessages(resp.data.reverse()))
  }, [verifiedRoomId])

  // Listen to realtime changes based on INSERT events to the messages table
  useEffect(() => {
    if (!verifiedRoomId) return

    const newChannel = realtimeClient.channel(`room:public:messages:room_id=eq.${verifiedRoomId}`)
    newChannel.on(
      'realtime',
      (payload: any) =>
        setMessages((prevMsgs: any) => {
          let msgs = prevMsgs.slice(-9)
          const msg = (({ id, message, room_id, user_id }) => ({
            id,
            message,
            room_id,
            user_id,
          }))(payload.payload.record)
          msgs.push(msg)
          return msgs
        }),
      { event: 'INSERT' }
    )
    newChannel.subscribe()
    setRoomChannel(newChannel)

    return () => {
      newChannel.unsubscribe()
      realtimeClient.remove(newChannel)
    }
  }, [verifiedRoomId])

  // Handle event listeners to broadcast
  useEffect(() => {
    if (!channel) return

    const setMouseEvent = (e: MouseEvent) => {
      channel.send({
        type: 'broadcast',
        event: 'POS',
        payload: { user_id: userId, x: e.clientX, y: e.clientY },
      })
    }

    const onKeyPress = (e: KeyboardEvent) => {
      console.log('onKeyPress')
    }

    window.addEventListener('mousemove', setMouseEvent)
    window.addEventListener('keypress', onKeyPress)

    return () => {
      window.removeEventListener('mousemove', setMouseEvent)
      window.removeEventListener('keypress', onKeyPress)
    }
  }, [channel])

  if (!verifiedRoomId) return <Loader />

  return (
    <div
      className="h-screen w-screen p-4 animate-gradient flex flex-col justify-between relative"
      style={{
        background:
          'linear-gradient(-45deg, transparent, transparent, rgba(0, 89, 60, 0.5), rgba(0, 207, 144, 0.5), rgba(0, 89, 60, 0.5), transparent, transparent)',
        backgroundSize: '400% 400%',
      }}
    >
      {/* Fixed elements */}
      <div>
        <div className="flex justify-between">
          <WaitlistPopover />
          <Users users={users} />
        </div>
      </div>

      <div className="flex justify-end">
        <Chatbox messages={messages} roomId={verifiedRoomId} userId={userId} />
      </div>

      {/* Floating elements */}
      {Object.entries(users).map(([userId, data]) => {
        return <Cursor key={userId} x={data.x} y={data.y} color={data.color} />
      })}
    </div>
  )
}

export default Room
