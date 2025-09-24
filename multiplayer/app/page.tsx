import { ThemeSwitcher } from "@/components/theme-switcher";
import { RealtimeCursors } from '@/components/realtime-cursors'
import { RealtimeChat } from '@/components/realtime-chat'
import { RealtimeAvatarStack } from '@/components/realtime-avatar-stack'
import { LatencyIndicator } from '@/components/latency-indicator'
import { nanoid } from 'nanoid'

const generateRandomColor = () => `hsl(${Math.floor(Math.random() * 360)}, 100%, 70%)`


export default function Home() {
  const color = generateRandomColor()
  const userId = nanoid()

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
        <div className="flex justify-between flex-row-reverse">
          <RealtimeAvatarStack roomName="presence-room" color={color} />
        </div>
        <div className="flex items-end justify-between">
          <div className="flex items-center space-x-4">
            <LatencyIndicator/>
            <ThemeSwitcher />
          </div>
          <div className="flex justify-end">
          <RealtimeChat roomName="chat-room" username={userId} />
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
      <RealtimeCursors roomName="cursor-room" color={color} />
    </div>
  )
}
