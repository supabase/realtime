import { ThemeSwitcher } from "@/components/theme-switcher";
import { RealtimeCursors } from '@/components/realtime-cursors'
import { RealtimeChat } from '@/components/realtime-chat'
import { RealtimeAvatarStack } from '@/components/realtime-avatar-stack'
import { LatencyIndicator } from '@/components/latency-indicator'
import { nanoid } from 'nanoid'

const generateRandomColor = () => `hsl(${Math.floor(Math.random() * 360)}, 100%, 70%)`

function IconMenuRealtime({ width = "16", height = "16", className = "" }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      width={width}
      height={height}
      viewBox="0 0 16 16"
      fill="none"
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M5.85669 1.07837C6.13284 1.07837 6.35669 1.30223 6.35669 1.57837V4.07172C6.35669 4.34786 6.13284 4.57172 5.85669 4.57172C5.58055 4.57172 5.35669 4.34786 5.35669 4.07172V1.57837C5.35669 1.30223 5.58055 1.07837 5.85669 1.07837ZM1.51143 1.51679C1.70961 1.32449 2.02615 1.32925 2.21845 1.52743L4.3494 3.72353C4.5417 3.9217 4.53694 4.23825 4.33876 4.43055C4.14058 4.62285 3.82403 4.61809 3.63173 4.41991L1.50078 2.22381C1.30848 2.02564 1.31325 1.70909 1.51143 1.51679ZM5.10709 6.49114C4.74216 5.65659 5.59204 4.80844 6.42584 5.17508L14.3557 8.66199C15.2287 9.04582 15.1201 10.3175 14.1948 10.5478L11.1563 11.3041L10.4159 14.1716C10.1783 15.0916 8.91212 15.1928 8.53142 14.3222L5.10709 6.49114ZM13.9532 9.5774L6.02332 6.09049L9.44766 13.9216L10.2625 10.7658C10.3083 10.5882 10.4478 10.4499 10.6258 10.4056L13.9532 9.5774ZM1.04663 5.79688C1.04663 5.52073 1.27049 5.29688 1.54663 5.29688H3.99057C4.26671 5.29688 4.49057 5.52073 4.49057 5.79688C4.49057 6.07302 4.26671 6.29688 3.99057 6.29688H1.54663C1.27049 6.29688 1.04663 6.07302 1.04663 5.79688Z"
        fill="currentColor"
      />
    </svg>
  )
}

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
          <IconMenuRealtime width="23" height="23" className="" />
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
