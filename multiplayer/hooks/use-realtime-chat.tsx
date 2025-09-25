'use client'

import { createClient } from '@/lib/supabase/client'
import { useCallback, useEffect, useState } from 'react'

interface UseRealtimeChatProps {
  roomName: string
  username: string
}

export interface ChatMessage {
  id: string
  content: string
  username: string
  createdAt: string
  replayed: boolean
}

const EVENT_MESSAGE_TYPE = 'message'

export function useRealtimeChat({ roomName, username }: UseRealtimeChatProps) {
  const supabase = createClient()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [channel, setChannel] = useState<ReturnType<typeof supabase.channel> | null>(null)

  const twelveHours = 12 * 60 * 60 * 1000
  const twelveHoursAgo = Date.now() - twelveHours

 const [isConnected, setIsConnected] = useState(false)

  useEffect(() => {
    const config = { private: true, broadcast: { replay: { since: twelveHoursAgo } } }
    // @ts-ignore
    const newChannel = supabase.channel(roomName, { config })

    newChannel
      .on('broadcast', { event: EVENT_MESSAGE_TYPE }, (payload) => {
        const chatMessage = payload.payload as ChatMessage
        chatMessage.replayed = payload?.meta?.replayed
        setMessages((current) => [...current, chatMessage])
      })
      .subscribe(async (status) => {
        if (status === 'SUBSCRIBED') {
          setIsConnected(true)
        }
      })

    setChannel(newChannel)

    return () => {
      supabase.removeChannel(newChannel)
    }
  }, [roomName, username, supabase])

  const sendMessage = useCallback(
    async (content: string) => {
      if (!channel || !isConnected) return

      const message: ChatMessage = {
        id: crypto.randomUUID(),
        content,
        username,
        createdAt: new Date().toISOString(),
        replayed: false
      }

      // Update local state immediately for the sender
      setMessages((current) => [...current, message])

      await supabase.from('new_messages').insert([
        {
          id: message.id,
          content,
          username,
          room: roomName
        },
      ])
    },
    [channel, isConnected, username]
  )

  return { messages, sendMessage, isConnected }
}
