import { ThemeSwitcher } from "@/components/theme-switcher";
import Link from "next/link";
import { RealtimeCursors } from '@/components/realtime-cursors'
import { nanoid } from 'nanoid'

// Generate a random user id
const userId = nanoid()

export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center">
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
      <RealtimeCursors roomName="macrodata_refinement_office" username="Mark Scout" />
    </main>
  );
}
