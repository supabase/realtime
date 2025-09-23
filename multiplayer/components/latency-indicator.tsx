'use client'

import { Badge } from '@/components/ui/badge'
import { useRealtimeLatencyRoom } from '@/hooks/use-realtime-latency-room'
import { nanoid } from 'nanoid'

export const LatencyIndicator = () => {
  const { latency } = useRealtimeLatencyRoom(nanoid())

  return <Badge>Latency: {latency.toFixed(0)}ms</Badge>
}
