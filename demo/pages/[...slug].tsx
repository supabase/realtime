import { useEffect, useState, useRef, ReactElement } from 'react'
import type { NextPage } from 'next'
import { useRouter } from 'next/router'
import { nanoid } from 'nanoid'
import cloneDeep from 'lodash.clonedeep'
import throttle from 'lodash.throttle'
import { Badge } from '@supabase/ui'
import {
  PostgrestResponse,
  REALTIME_LISTEN_TYPES,
  REALTIME_POSTGRES_CHANGES_LISTEN_EVENT,
  REALTIME_PRESENCE_LISTEN_EVENTS,
  REALTIME_SUBSCRIBE_STATES,
  RealtimeChannel,
  RealtimeChannelSendResponse,
  RealtimePostgresInsertPayload,
} from '@supabase/supabase-js'

import supabaseClient from '../client'
import { Coordinates, Message, Payload, User } from '../types'
import { removeFirst } from '../utils'
import { getRandomColor, getRandomColors, getRandomUniqueColor } from '../lib/RandomColor'
import { sendLog } from '../lib/sendLog'

import Chatbox from '../components/Chatbox'
import Cursor from '../components/Cursor'
import Loader from '../components/Loader'
import Users from '../components/Users'
import WaitlistPopover from '../components/WaitlistPopover'
import DarkModeToggle from '../components/DarkModeToggle'

const LATENCY_THRESHOLD = 400
const MAX_ROOM_USERS = 50
const MAX_DISPLAY_MESSAGES = 50
const MAX_EVENTS_PER_SECOND = 10
const X_THRESHOLD = 25
const Y_THRESHOLD = 35

// Generate a random user id
const userId = nanoid()

const Room: NextPage = () => {
  const router = useRouter()

  const localColorBackup = getRandomColor()

  const chatboxRef = useRef<any>()
  // [Joshen] Super hacky fix for a really weird bug for onKeyDown
  // input field. For some reason the first keydown event appends the character twice
  const chatInputFix = useRef<boolean>(true)

  // These states will be managed via ref as they're mutated within event listeners
  const usersRef = useRef<{ [key: string]: User }>({})
  const isTypingRef = useRef<boolean>(false)
  const isCancelledRef = useRef<boolean>(false)
  const messageRef = useRef<string>()
  const messagesInTransitRef = useRef<string[]>()
  const mousePositionRef = useRef<Coordinates>()

  const joinTimestampRef = useRef<number>()
  const insertMsgTimestampRef = useRef<number>()

  // We manage the refs with a state so that the UI can re-render
  const [isTyping, _setIsTyping] = useState<boolean>(false)
  const [isCancelled, _setIsCancelled] = useState<boolean>(false)
  const [message, _setMessage] = useState<string>('')
  const [messagesInTransit, _setMessagesInTransit] = useState<string[]>([])
  const [mousePosition, _setMousePosition] = useState<Coordinates>()

  const [areMessagesFetched, setAreMessagesFetched] = useState<boolean>(false)
  const [isInitialStateSynced, setIsInitialStateSynced] = useState<boolean>(false)
  const [latency, setLatency] = useState<number>(0)
  const [messages, setMessages] = useState<Message[]>([])
  const [roomId, setRoomId] = useState<undefined | string>(undefined)
  const [users, setUsers] = useState<{ [key: string]: User }>({})

  const setIsTyping = (value: boolean) => {
    isTypingRef.current = value
    _setIsTyping(value)
  }

  const setIsCancelled = (value: boolean) => {
    isCancelledRef.current = value
    _setIsCancelled(value)
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

  const mapInitialUsers = (userChannel: RealtimeChannel, roomId: string) => {
    const state = userChannel.presenceState()
    const _users = state[roomId]

    if (!_users) return

    // Deconflict duplicate colours at the beginning of the browser session
    const colors = Object.keys(usersRef.current).length === 0 ? getRandomColors(_users.length) : []

    if (_users) {
      setUsers((existingUsers) => {
        const updatedUsers = _users.reduce(
          (acc: { [key: string]: User }, { user_id: userId }: any, index: number) => {
            const userColors = Object.values(usersRef.current).map((user: any) => user.color)
            // Deconflict duplicate colors for incoming clients during the browser session
            const color = colors.length > 0 ? colors[index] : getRandomUniqueColor(userColors)

            acc[userId] = existingUsers[userId] || {
              x: 0,
              y: 0,
              color: color.bg,
              hue: color.hue,
            }
            return acc
          },
          {}
        )
        usersRef.current = updatedUsers
        return updatedUsers
      })
    }
  }

  useEffect(() => {
    let roomChannel: RealtimeChannel

    const { slug } = router.query
    const slugRoomId = Array.isArray(slug) ? slug[0] : undefined

    if (!roomId) {
      // roomId is undefined when user first attempts to join a room

      joinTimestampRef.current = performance.now()

      /* 
        Client is joining 'rooms' channel to examine existing rooms and their users
        and then the channel is removed once a room is selected
      */
      roomChannel = supabaseClient.channel('rooms')

      roomChannel
        .on(REALTIME_LISTEN_TYPES.PRESENCE, { event: REALTIME_PRESENCE_LISTEN_EVENTS.SYNC }, () => {
          let newRoomId
          const state = roomChannel.presenceState()

          // User attempting to navigate directly to an existing room with users
          if (slugRoomId && slugRoomId in state && state[slugRoomId].length < MAX_ROOM_USERS) {
            newRoomId = slugRoomId
          }

          // User will be assigned an existing room with the fewest users
          if (!newRoomId) {
            const [mostVacantRoomId, users] =
              Object.entries(state).sort(([, a], [, b]) => a.length - b.length)[0] ?? []

            if (users && users.length < MAX_ROOM_USERS) {
              newRoomId = mostVacantRoomId
            }
          }

          // Generate an id if no existing rooms are available
          setRoomId(newRoomId ?? nanoid())
        })
        .subscribe()
    } else {
      // When user has been placed in a room

      joinTimestampRef.current &&
        sendLog(
          `User ${userId} joined Room ${roomId} in ${(
            performance.now() - joinTimestampRef.current
          ).toFixed(1)} ms`
        )

      /* 
        Client is re-joining 'rooms' channel and the user's id will be tracked with Presence.

        Note: Realtime enforces unique channel names per client so the previous 'rooms' channel
        has already been removed in the cleanup function.
      */
      roomChannel = supabaseClient.channel('rooms', { config: { presence: { key: roomId } } })
      roomChannel.on(
        REALTIME_LISTEN_TYPES.PRESENCE,
        { event: REALTIME_PRESENCE_LISTEN_EVENTS.SYNC },
        () => {
          setIsInitialStateSynced(true)
          mapInitialUsers(roomChannel, roomId)
        }
      )
      roomChannel.subscribe(async (status: `${REALTIME_SUBSCRIBE_STATES}`) => {
        if (status === REALTIME_SUBSCRIBE_STATES.SUBSCRIBED) {
          const resp: RealtimeChannelSendResponse = await roomChannel.track({ user_id: userId })

          if (resp === 'ok') {
            router.push(`/${roomId}`)
          } else {
            router.push(`/`)
          }
        }
      })

      // Get the room's existing messages that were saved to database
      supabaseClient
        .from('messages')
        .select('id, user_id, message')
        .filter('room_id', 'eq', roomId)
        .order('created_at', { ascending: false })
        .limit(MAX_DISPLAY_MESSAGES)
        .then((resp: PostgrestResponse<Message>) => {
          resp.data && setMessages(resp.data.reverse())
          setAreMessagesFetched(true)
          if (chatboxRef.current) chatboxRef.current.scrollIntoView({ behavior: 'smooth' })
        })
    }

    // Must properly remove subscribed channel
    return () => {
      roomChannel && supabaseClient.removeChannel(roomChannel)
    }

    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roomId])

  useEffect(() => {
    if (!roomId || !isInitialStateSynced) return

    let pingIntervalId: ReturnType<typeof setInterval> | undefined
    let messageChannel: RealtimeChannel, pingChannel: RealtimeChannel
    let setMouseEvent: (e: MouseEvent) => void = () => {},
      onKeyDown: (e: KeyboardEvent) => void = () => {}

    // Ping channel is used to calculate roundtrip time from client to server to client
    pingChannel = supabaseClient.channel(`ping:${userId}`, {
      config: { broadcast: { ack: true } },
    })
    pingChannel.subscribe((status: `${REALTIME_SUBSCRIBE_STATES}`) => {
      if (status === REALTIME_SUBSCRIBE_STATES.SUBSCRIBED) {
        pingIntervalId = setInterval(async () => {
          const start = performance.now()
          const resp = await pingChannel.send({
            type: 'broadcast',
            event: 'PING',
            payload: {},
          })

          if (resp !== 'ok') {
            console.log('pingChannel broadcast error')
            setLatency(-1)
          } else {
            const end = performance.now()
            const newLatency = end - start

            if (newLatency >= LATENCY_THRESHOLD) {
              sendLog(
                `Roundtrip Latency for User ${userId} surpassed ${LATENCY_THRESHOLD} ms at ${newLatency.toFixed(
                  1
                )} ms`
              )
            }

            setLatency(newLatency)
          }
        }, 1000)
      }
    })

    messageChannel = supabaseClient.channel(`chat_messages:${roomId}`)

    // Listen for messages inserted into the database
    messageChannel.on(
      REALTIME_LISTEN_TYPES.POSTGRES_CHANGES,
      {
        event: REALTIME_POSTGRES_CHANGES_LISTEN_EVENT.INSERT,
        schema: 'public',
        table: 'messages',
        filter: `room_id=eq.${roomId}`,
      },
      (
        payload: RealtimePostgresInsertPayload<{
          id: number
          created_at: string
          message: string
          user_id: string
          room_id: string
        }>
      ) => {
        if (payload.new.user_id === userId && insertMsgTimestampRef.current) {
          sendLog(
            `Message Latency for User ${userId} from insert to receive was ${(
              performance.now() - insertMsgTimestampRef.current
            ).toFixed(1)} ms`
          )
          insertMsgTimestampRef.current = undefined
        }

        setMessages((prevMsgs: Message[]) => {
          const messages = prevMsgs.slice(-MAX_DISPLAY_MESSAGES + 1)
          const msg = (({ id, message, room_id, user_id }) => ({
            id,
            message,
            room_id,
            user_id,
          }))(payload.new)
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
      }
    )

    // Listen for cursor positions from other users in the room
    messageChannel.on(
      REALTIME_LISTEN_TYPES.BROADCAST,
      { event: 'POS' },
      (payload: Payload<{ user_id: string } & Coordinates>) => {
        setUsers((users) => {
          const userId = payload!.payload!.user_id
          const existingUser = users[userId]

          if (existingUser) {
            const x =
              (payload?.payload?.x ?? 0) - X_THRESHOLD > window.innerWidth
                ? window.innerWidth - X_THRESHOLD
                : payload?.payload?.x
            const y =
              (payload?.payload?.y ?? 0 - Y_THRESHOLD) > window.innerHeight
                ? window.innerHeight - Y_THRESHOLD
                : payload?.payload?.y

            users[userId] = { ...existingUser, ...{ x, y } }
            users = cloneDeep(users)
          }

          return users
        })
      }
    )

    // Listen for messages sent by other users directly via Broadcast
    messageChannel.on(
      REALTIME_LISTEN_TYPES.BROADCAST,
      { event: 'MESSAGE' },
      (payload: Payload<{ user_id: string; isTyping: boolean; message: string }>) => {
        setUsers((users) => {
          const userId = payload!.payload!.user_id
          const existingUser = users[userId]

          if (existingUser) {
            users[userId] = {
              ...existingUser,
              ...{ isTyping: payload?.payload?.isTyping, message: payload?.payload?.message },
            }
            users = cloneDeep(users)
          }

          return users
        })
      }
    )
    messageChannel.subscribe((status: `${REALTIME_SUBSCRIBE_STATES}`) => {
      if (status === REALTIME_SUBSCRIBE_STATES.SUBSCRIBED) {
        // Lodash throttle will be removed once realtime-js client throttles on the channel level
        const sendMouseBroadcast = throttle(({ x, y }) => {
          messageChannel
            .send({
              type: 'broadcast',
              event: 'POS',
              payload: { user_id: userId, x, y },
            })
            .catch(() => {})
        }, 1000 / MAX_EVENTS_PER_SECOND)

        setMouseEvent = (e: MouseEvent) => {
          const [x, y] = [e.clientX, e.clientY]
          sendMouseBroadcast({ x, y })
          setMousePosition({ x, y })
        }

        onKeyDown = async (e: KeyboardEvent) => {
          if (document.activeElement?.id === 'email') return

          // Start typing session
          if (e.code === 'Enter' || (e.key.length === 1 && !e.metaKey)) {
            if (!isTypingRef.current) {
              setIsTyping(true)
              setIsCancelled(false)

              if (chatInputFix.current) {
                setMessage('')
                chatInputFix.current = false
              } else {
                setMessage(e.key.length === 1 ? e.key : '')
              }
              messageChannel
                .send({
                  type: 'broadcast',
                  event: 'MESSAGE',
                  payload: { user_id: userId, isTyping: true, message: '' },
                })
                .catch(() => {})
            } else if (e.code === 'Enter') {
              // End typing session and send message
              setIsTyping(false)
              messageChannel
                .send({
                  type: 'broadcast',
                  event: 'MESSAGE',
                  payload: { user_id: userId, isTyping: false, message: messageRef.current },
                })
                .catch(() => {})
              if (messageRef.current) {
                const updatedMessagesInTransit = (messagesInTransitRef?.current ?? []).concat([
                  messageRef.current,
                ])
                setMessagesInTransit(updatedMessagesInTransit)
                if (chatboxRef.current) chatboxRef.current.scrollIntoView({ behavior: 'smooth' })
                insertMsgTimestampRef.current = performance.now()
                await supabaseClient.from('messages').insert([
                  {
                    user_id: userId,
                    room_id: roomId,
                    message: messageRef.current,
                  },
                ])
              }
            }
          }

          // End typing session without sending
          if (e.code === 'Escape' && isTypingRef.current) {
            setIsTyping(false)
            setIsCancelled(true)
            chatInputFix.current = true

            messageChannel
              .send({
                type: 'broadcast',
                event: 'MESSAGE',
                payload: { user_id: userId, isTyping: false, message: '' },
              })
              .catch(() => {})
          }
        }

        window.addEventListener('mousemove', setMouseEvent)
        window.addEventListener('keydown', onKeyDown)
      }
    })

    return () => {
      pingIntervalId && clearInterval(pingIntervalId)

      window.removeEventListener('mousemove', setMouseEvent)
      window.removeEventListener('keydown', onKeyDown)

      pingChannel && supabaseClient.removeChannel(pingChannel)
      messageChannel && supabaseClient.removeChannel(messageChannel)
    }

    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roomId, isInitialStateSynced])

  if (!roomId) {
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
          <div className="flex items-center space-x-4">
            <DarkModeToggle />
            <Badge>Latency: {latency.toFixed(1)}ms</Badge>
          </div>
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
              isTyping={isTyping || false}
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
          color={users[userId]?.color ?? localColorBackup.bg}
          hue={users[userId]?.hue ?? localColorBackup.hue}
          isTyping={isTyping}
          isCancelled={isCancelled}
          message={message}
          onUpdateMessage={setMessage}
        />
      )}
    </div>
  )
}

export default Room
