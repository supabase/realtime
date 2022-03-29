import type { NextPage } from 'next'
import randomColor from 'randomcolor'
import { useEffect, useState, useRef } from 'react'
import { useRouter } from 'next/router'
import { nanoid } from 'nanoid'
import cloneDeep from 'lodash.clonedeep'

import { Coordinate, User, Message } from '../types/main.type'
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

  const [users, setUsers] = useState<{ [key: string]: User }>({})
  const [messages, setMessages] = useState<Message[]>([])
  const [roomChannel, setRoomChannel] = useState<RealtimeSubscriptionV2>()

  // These states will be managed via ref as their mutated within event listeners
  const isTypingRef = useRef() as any
  const messageRef = useRef() as any
  const mousePositionRef = useRef() as any
  // We manage the refs with a state so that the UI can rerender
  const [isTyping, _setIsTyping] = useState<boolean>(false)
  const [message, _setMessage] = useState<string>('')
  const [mousePosition, _setMousePosition] = useState<Coordinate>({ x: 0, y: 0 })

  const setIsTyping = (value: boolean) => {
    isTypingRef.current = value
    _setIsTyping(value)
  }

  const setMessage = (value: string) => {
    messageRef.current = value
    _setMessage(value)
  }

  const setMousePosition = (coordinates: Coordinate) => {
    mousePositionRef.current = coordinates
    _setMousePosition(coordinates)
  }

  // Initialize realtime session
  useEffect(() => {
    isTypingRef.current = false
    setMousePosition({ x: 0, y: 0 })

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

  // Handle presence and position of users within the room
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
                message: '',
                isTyping: false,
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
      (payload: any) => {
        setUsers((users) => {
          const usersClone = cloneDeep(users)
          const userId = payload.payload.user_id
          usersClone[userId] = {
            ...usersClone[userId],
            ...{ x: payload.payload.x, y: payload.payload.y },
          }
          return usersClone
        })
      },
      { event: 'POS' }
    )

    channel.on(
      'broadcast',
      (payload: any) => {
        setUsers((users) => {
          const usersClone = cloneDeep(users)
          const userId = payload.payload.user_id
          usersClone[userId] = {
            ...usersClone[userId],
            ...{ isTyping: payload.payload.isTyping, message: payload.payload.message },
          }
          return usersClone
        })
      },
      { event: 'MESSAGE' }
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
      setMousePosition({ x: e.clientX, y: e.clientY })
    }

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.code === 'Enter') {
        if (!isTypingRef.current) {
          setIsTyping(true)
          setMessage('')
          channel.send({
            type: 'broadcast',
            event: 'MESSAGE',
            payload: { user_id: userId, isTyping: true, message: '' },
          })
        } else {
          setIsTyping(false)
          channel.send({
            type: 'broadcast',
            event: 'MESSAGE',
            payload: { user_id: userId, isTyping: false, message: messageRef.current },
          })
        }
      }
      if (e.code === 'Escape' && isTypingRef.current) {
        setIsTyping(false)
        channel.send({
          type: 'broadcast',
          event: 'MESSAGE',
          payload: { user_id: userId, isTyping: false, message: '' },
        })
      }
    }

    window.addEventListener('mousemove', setMouseEvent)
    window.addEventListener('keydown', onKeyDown)

    return () => {
      window.removeEventListener('mousemove', setMouseEvent)
      window.removeEventListener('keydown', onKeyDown)
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
      <div className="flex justify-between">
        <WaitlistPopover />
        <Users users={users} />
      </div>

      <div className="absolute top-0 left-0 w-full h-full flex items-center justify-center space-x-2 pointer-events-none">
        <div className="flex items-center justify-center space-x-2 border border-scale-1200 rounded-md px-3 py-2 opacity-20">
          <p className="text-scale-1200 cursor-default text-sm">Chat</p>
          <code className="bg-scale-1100 text-scale-100 px-1 h-6 rounded flex items-center justify-center">
            ↩
          </code>
        </div>
        <div className="flex items-center justify-center space-x-2 border border-scale-1200 rounded-md px-3 py-2 opacity-20">
          <p className="text-scale-1200 cursor-default text-sm">Escape</p>
          <code className="bg-scale-1100 text-scale-100 px-1 h-6 rounded flex items-center justify-center text-xs">
            ESC
          </code>
        </div>
      </div>

      {Object.entries(users).map(([userId, data]) => {
        return (
          <Cursor
            key={userId}
            x={data.x}
            y={data.y}
            color={data.color}
            message={data.message || ''}
            isTyping={data.isTyping}
          />
        )
      })}

      {/* Cursor for local client: Shouldn't show the cursor itself, only the text bubble */}
      <Cursor
        isLocalClient
        x={mousePosition.x}
        y={mousePosition.y}
        color="#3ECF8E"
        isTyping={isTyping}
        message={message}
        onUpdateMessage={setMessage}
      />

      <div className="flex justify-end">
        <Chatbox messages={messages} roomId={verifiedRoomId} userId={userId} />
      </div>
    </div>
  )
}

export default Room
