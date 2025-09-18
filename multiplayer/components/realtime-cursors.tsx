'use client'

import { Cursor } from '@/components/cursor'
import { useRealtimeCursors } from '@/hooks/use-realtime-cursors'

const THROTTLE_MS = 50

export const RealtimeCursors = ({ roomName }: { roomName: string }) => {
  const { cursors } = useRealtimeCursors({ roomName, throttleMs: THROTTLE_MS })

  return (
    <div>
      {Object.keys(cursors).map((id) => (
        <Cursor
          key={id}
          className="fixed transition-transform ease-in-out z-50"
          style={{
            transitionDuration: '100ms',
            top: 0,
            left: 0,
            transform: `translate(${cursors[id].position.x}px, ${cursors[id].position.y}px)`,
          }}
          color={cursors[id].color}
        />
      ))}
    </div>
  )
}
