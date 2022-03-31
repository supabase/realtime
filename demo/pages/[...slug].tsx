import type { NextPage } from 'next'
import { useRouter } from 'next/router'
import { useEffect, useState, useRef, ReactElement } from 'react'

import cloneDeep from 'lodash.clonedeep'
import { nanoid } from 'nanoid'
import randomColor from 'randomcolor'

import { supabaseClient, realtimeClient } from '../clients'

import { RealtimeChannel } from '@supabase/realtime-js'
import { PostgrestResponse } from '@supabase/supabase-js'

import Chatbox from '../components/Chatbox'
import Cursor from '../components/Cursor'
import Loader from '../components/Loader'
import Users from '../components/Users'
import WaitlistPopover from '../components/WaitlistPopover'

import { Coordinates, DatabaseChange, Message, Payload, User } from '../types'
import logger from '../logger'

const MAX_ROOM_USERS = 5
const userId = nanoid()

const Room: NextPage = () => {
  const router = useRouter()
  const { slug } = router.query
  const currentRoomId = slug && slug[0]

  const [userChannel, setUserChannel] = useState<RealtimeChannel>()
  const [messageChannel, setMessageChannel] = useState<RealtimeChannel>()

  const [isInitialStateSynced, setIsInitialStateSynced] = useState<boolean>(false)
  const [validatedRoomId, setValidatedRoomId] = useState<string>()

  const [users, setUsers] = useState<{ [key: string]: User }>({})
  const [messages, setMessages] = useState<Message[]>([])

  // These states will be managed via ref as they're mutated within event listeners
  const isTypingRef = useRef<boolean>(false)
  const messageRef = useRef<string>()
  const mousePositionRef = useRef<Coordinates>()

  // We manage the refs with a state so that the UI can re-render
  const [isTyping, _setIsTyping] = useState<boolean>(false)
  const [message, _setMessage] = useState<string>('')
  const [mousePosition, _setMousePosition] = useState<Coordinates>()

  const setIsTyping = (value: boolean) => {
    isTypingRef.current = value
    _setIsTyping(value)
  }

  const setMessage = (value: string) => {
    messageRef.current = value
    _setMessage(value)
  }

  const setMousePosition = (coordinates: Coordinates) => {
    mousePositionRef.current = coordinates
    _setMousePosition(coordinates)
  }

  // Connect to socket and subscribe to user channel
  useEffect(() => {
    realtimeClient.connect()

    // Set up user channel and subscribe
    const userChannel = realtimeClient.channel('room:*', { isNewVersion: true }) as RealtimeChannel
    userChannel.on('presence', { event: 'SYNC' }, () => {
      setIsInitialStateSynced(true)
    })
    userChannel.subscribe()
    setUserChannel(userChannel)

    return () => {
      userChannel.unsubscribe()
      realtimeClient.remove(userChannel)
      realtimeClient.disconnect()
    }
  }, [])

  // Determine if current room is valid or generate a new room id
  useEffect(() => {
    if (!isInitialStateSynced || !currentRoomId || !userChannel) {
      return
    }

    let newRoomId: string | undefined
    const state = userChannel.presence.state
    const presences = state[currentRoomId]

    if (presences?.length < MAX_ROOM_USERS) {
      newRoomId = currentRoomId
    } else if (Object.keys(state).length) {
      const existingRooms: [string, number][] = Object.entries(state).map(([roomId, users]) => [
        roomId,
        users.length,
      ])
      const sortedRooms = existingRooms.sort((a: any, b: any) => a[1] - b[1])
      const [existingRoomId, roomCount] = sortedRooms[0]

      if (roomCount < MAX_ROOM_USERS) {
        newRoomId = existingRoomId
      }
    }

    if (!newRoomId) {
      newRoomId = nanoid()
    }

    userChannel
      .send({
        type: 'presence',
        event: 'TRACK',
        key: newRoomId,
        payload: { user_id: userId },
      })
      .then((status) => {
        if (status === 'ok') {
          if (currentRoomId !== newRoomId) {
            router.push(`/${newRoomId}`)
          } else {
            setValidatedRoomId(newRoomId)
            logger?.info(`User joined: ${userId}`, {
              user_id: userId,
              room_id: newRoomId,
              timestamp: Date.now(),
            })
          }
        } else {
          router.push('/')
        }
      })
  }, [currentRoomId, router, isInitialStateSynced, userChannel])

  // Fetch chat messages
  useEffect(() => {
    if (!validatedRoomId) {
      return
    }

    supabaseClient
      .from('messages')
      .select('id, user_id, message')
      .filter('room_id', 'eq', validatedRoomId)
      .order('created_at', { ascending: false })
      .limit(10)
      .then((resp: PostgrestResponse<Message>) => resp.data && setMessages(resp.data.reverse()))
  }, [validatedRoomId])

  // Continue to sync user presence state after initial state sync
  useEffect(() => {
    if (!isInitialStateSynced || !userChannel || !validatedRoomId) {
      return
    }

    userChannel.off('presence', { event: 'SYNC' })

    userChannel.on('presence', { event: 'SYNC' }, () => {
      const state = userChannel.presence.state
      const users = state[validatedRoomId]

      if (users) {
        setUsers((existingUsers) => {
          return users.reduce((acc: { [key: string]: User }, { user_id: userId }: any) => {
            acc[userId] = existingUsers[userId] || { color: randomColor() }
            return acc
          }, {})
        })
      }
    })
  }, [isInitialStateSynced, userChannel, validatedRoomId])

  // Listen to database changes for chat messages and handle broadcast messages
  useEffect(() => {
    if (!validatedRoomId) {
      return
    }

    const messageChannel = realtimeClient.channel(
      `room:public:messages:room_id=eq.${validatedRoomId}`,
      {
        isNewVersion: true,
      }
    ) as RealtimeChannel

    messageChannel.on('realtime', { event: 'INSERT' }, (payload: Payload<DatabaseChange>) =>
      setMessages((prevMsgs: Message[]) => {
        const messages = prevMsgs.slice(-9)
        const msg = (({ id, message, room_id, user_id }) => ({
          id,
          message,
          room_id,
          user_id,
        }))(payload.payload.record)
        messages.push(msg)
        return messages
      })
    )

    messageChannel.on(
      'broadcast',
      { event: 'POS' },
      (payload: Payload<{ user_id: string } & Coordinates>) => {
        setUsers((users) => {
          const userId = payload.payload.user_id
          const existingUser = users[userId]

          if (existingUser) {
            users[userId] = { ...existingUser, ...{ x: payload.payload.x, y: payload.payload.y } }
            users = cloneDeep(users)
          }

          return users
        })
      }
    )

    messageChannel.on(
      'broadcast',
      { event: 'MESSAGE' },
      (payload: Payload<{ user_id: string; isTyping: boolean; message: string }>) => {
        setUsers((users) => {
          const userId = payload.payload.user_id
          const existingUser = users[userId]

          if (existingUser) {
            users[userId] = {
              ...existingUser,
              ...{ isTyping: payload.payload.isTyping, message: payload.payload.message },
            }
            users = cloneDeep(users)
          }

          return users
        })
      }
    )

    messageChannel.subscribe()
    setMessageChannel(messageChannel)

    return () => {
      messageChannel.unsubscribe()
      realtimeClient.remove(messageChannel)
    }
  }, [validatedRoomId])

  // Handle event listeners to broadcast
  useEffect(() => {
    if (!messageChannel) {
      return
    }

    const setMouseEvent = (e: MouseEvent) => {
      const [x, y] = [e.clientX, e.clientY]

      messageChannel.send({
        type: 'broadcast',
        event: 'POS',
        payload: { user_id: userId, x, y },
      })
      setMousePosition({ x, y })
    }

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.code === 'Enter') {
        if (!isTypingRef.current) {
          setIsTyping(true)
          setMessage('')
          messageChannel.send({
            type: 'broadcast',
            event: 'MESSAGE',
            payload: { user_id: userId, isTyping: true, message: '' },
          })
        } else {
          setIsTyping(false)
          messageChannel.send({
            type: 'broadcast',
            event: 'MESSAGE',
            payload: { user_id: userId, isTyping: false, message: messageRef.current },
          })
        }
      }

      if (e.code === 'Escape' && isTypingRef.current) {
        setIsTyping(false)
        messageChannel.send({
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
  }, [messageChannel])

  if (!validatedRoomId) {
    return <Loader />
  }

  return (
    <div
      className="h-screen w-screen p-4 animate-gradient flex flex-col justify-between relative overflow-hidden"
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

      {Object.entries(users).reduce((acc, [userId, data]) => {
        const { x, y, color, message, isTyping } = data
        if (x && y) {
          acc.push(
            <Cursor
              key={userId}
              x={x}
              y={y}
              color={color}
              message={message || ''}
              isTyping={isTyping}
            />
          )
        }
        return acc
      }, [] as ReactElement[])}

      {/* Cursor for local client: Shouldn't show the cursor itself, only the text bubble */}
      {mousePosition?.x && mousePosition?.y && (
        <Cursor
          isLocalClient
          x={mousePosition.x}
          y={mousePosition.y}
          color="#3ECF8E"
          isTyping={isTyping}
          message={message}
          onUpdateMessage={setMessage}
        />
      )}

      <div className="flex justify-end">
        <Chatbox messages={messages} roomId={validatedRoomId} userId={userId} />
      </div>
    </div>
  )
}

export default Room
