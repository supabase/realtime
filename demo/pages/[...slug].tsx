import type { NextPage } from 'next'
import { useRouter } from 'next/router'
import { nanoid } from 'nanoid'
import cloneDeep from 'lodash.clonedeep'
import randomColor from './../lib/RandomColor'
import { useEffect, useState, useRef, ReactElement } from 'react'
import { RealtimeChannel } from '@supabase/realtime-js'
import { PostgrestResponse } from '@supabase/supabase-js'

import logger from '../logger'
import { removeFirst } from '../utils'
import { supabaseClient, realtimeClient } from '../clients'
import { Coordinates, DatabaseChange, Message, Payload, User } from '../types'

import Chatbox from '../components/Chatbox'
import Cursor from '../components/Cursor'
import Loader from '../components/Loader'
import Users from '../components/Users'
import WaitlistPopover from '../components/WaitlistPopover'
import DarkModeToggle from '../components/DarkModeToggle'

const MAX_ROOM_USERS = 5
const MAX_DISPLAY_MESSAGES = 50
const userId = nanoid()

const Room: NextPage = () => {
  const router = useRouter()
  const { slug } = router.query
  const currentRoomId = slug && slug[0]

  const [validatedRoomId, setValidatedRoomId] = useState<string>()
  const [userChannel, setUserChannel] = useState<RealtimeChannel>()
  const [messageChannel, setMessageChannel] = useState<RealtimeChannel>()

  const [areMessagesFetched, setAreMessagesFetched] = useState<boolean>(false)
  const [isInitialStateSynced, setIsInitialStateSynced] = useState<boolean>(false)

  const [users, setUsers] = useState<{ [key: string]: User }>({})
  const [messages, setMessages] = useState<Message[]>([])

  const [localColor, _setLocalColor] = useState<any>(randomColor())

  const chatboxRef = useRef<any>()

  // These states will be managed via ref as they're mutated within event listeners
  const isTypingRef = useRef<boolean>(false)
  const messageRef = useRef<string>()
  const messagesInTransitRef = useRef<string[]>()
  const mousePositionRef = useRef<Coordinates>()

  // We manage the refs with a state so that the UI can re-render
  const [isTyping, _setIsTyping] = useState<boolean>(false)
  const [message, _setMessage] = useState<string>('')
  const [messagesInTransit, _setMessagesInTransit] = useState<string[]>([])
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

  const setMessagesInTransit = (messages: string[]) => {
    messagesInTransitRef.current = messages
    _setMessagesInTransit(messages)
  }

  // Connect to socket and subscribe to user channel
  useEffect(() => {
    realtimeClient.connect()

    // Set up user channel and subscribe
    const userChannel = realtimeClient.channel('room:*', { isNewVersion: true }) as RealtimeChannel
    userChannel.on('presence', { event: 'SYNC' }, () => {
      setIsInitialStateSynced(true)
    })
    userChannel.subscribe().receive('ok', () => setUserChannel(userChannel))

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
    const users = state[currentRoomId]

    if (users?.length < MAX_ROOM_USERS) {
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

    if (!users?.find((user) => user.user_id === userId)) {
      userChannel
        .send({
          type: 'presence',
          event: 'TRACK',
          key: newRoomId,
          payload: { user_id: userId },
        })
        .then((status) => {
          if (status === 'ok') {
            router.push(`/${newRoomId}`)
            setValidatedRoomId(newRoomId)
            logger?.info(`User joined: ${userId}`, {
              user_id: userId,
              room_id: newRoomId,
              timestamp: Date.now(),
            })
          }
        })
    }
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
      .limit(MAX_DISPLAY_MESSAGES)
      .then((resp: PostgrestResponse<Message>) => {
        resp.data && setMessages(resp.data.reverse())
        setAreMessagesFetched(true)
        if (chatboxRef.current) chatboxRef.current.scrollIntoView({ behavior: 'smooth' })
      })
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
            const colors = randomColor()
            acc[userId] = existingUsers[userId] || { x: 0, y: 0, color: colors.bg, hue: colors.hue }
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

    realtimeClient.connect()

    const messageChannel = realtimeClient.channel(
      `room:public:messages:room_id=eq.${validatedRoomId}`,
      {
        isNewVersion: true,
      }
    ) as RealtimeChannel

    messageChannel.on('realtime', { event: 'INSERT' }, (payload: Payload<DatabaseChange>) => {
      setMessages((prevMsgs: Message[]) => {
        const messages = prevMsgs.slice(-MAX_DISPLAY_MESSAGES + 1)
        const msg = (({ id, message, room_id, user_id }) => ({
          id,
          message,
          room_id,
          user_id,
        }))(payload.payload.record)
        messages.push(msg)

        if (msg.user_id === userId) {
          const updatedMessagesInTransit = removeFirst(
            messagesInTransitRef?.current ?? [],
            msg.message
          )
          setMessagesInTransit(updatedMessagesInTransit)
        }

        return messages
      })

      if (chatboxRef.current) {
        chatboxRef.current.scrollIntoView({ behavior: 'smooth' })
      }
    })

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

    messageChannel.subscribe().receive('ok', () => setMessageChannel(messageChannel))

    return () => {
      messageChannel.unsubscribe()
      realtimeClient.remove(messageChannel)
      realtimeClient.disconnect()
    }
  }, [validatedRoomId])

  // Handle event listeners to broadcast
  useEffect(() => {
    if (!messageChannel || !validatedRoomId) {
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

    const onKeyDown = async (e: KeyboardEvent) => {
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
          if (messageRef.current) {
            const updatedMessagesInTransit = (messagesInTransitRef?.current ?? []).concat([
              messageRef.current,
            ])
            setMessagesInTransit(updatedMessagesInTransit)
            if (chatboxRef.current) chatboxRef.current.scrollIntoView({ behavior: 'smooth' })
            await supabaseClient.from('messages').insert([
              {
                user_id: userId,
                room_id: validatedRoomId,
                message: messageRef.current,
              },
            ])
          }
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
  }, [messageChannel, validatedRoomId])

  if (!validatedRoomId) {
    return <Loader />
  }

  return (
    <div
      className={[
        'h-screen w-screen p-4 flex flex-col justify-between relative',
        'max-h-screen max-w-screen overflow-hidden',
      ].join(' ')}
    >
      <div
        className="absolute h-full w-full left-0 top-0 pointer-events-none"
        style={{
          opacity: 0.02,
          backgroundSize: '16px 16px',
          backgroundImage:
            'linear-gradient(to right, gray 1px, transparent 1px),\n    linear-gradient(to bottom, gray 1px, transparent 1px)',
        }}
      />
      <div className="flex flex-col h-full justify-between">
        <div className="flex justify-between">
          <WaitlistPopover />
          <Users users={users} />
        </div>
        <div className="flex items-end justify-between">
          <DarkModeToggle />
          <div className="flex justify-end">
            <Chatbox
              messages={messages || []}
              chatboxRef={chatboxRef}
              messagesInTransit={messagesInTransit}
              areMessagesFetched={areMessagesFetched}
            />
          </div>
        </div>
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
        const { x, y, color, message, isTyping, hue } = data
        if (x && y) {
          acc.push(
            <Cursor
              key={userId}
              x={x}
              y={y}
              color={color}
              hue={hue}
              message={message || ''}
              isTyping={isTyping}
            />
          )
        }
        return acc
      }, [] as ReactElement[])}

      {/* Cursor for local client: Shouldn't show the cursor itself, only the text bubble */}
      {Number.isInteger(mousePosition?.x) && Number.isInteger(mousePosition?.y) && (
        <Cursor
          isLocalClient
          x={mousePosition?.x}
          y={mousePosition?.y}
          color={localColor.bg}
          hue={localColor.hue}
          isTyping={isTyping}
          message={message}
          onUpdateMessage={setMessage}
        />
      )}
    </div>
  )
}

export default Room
