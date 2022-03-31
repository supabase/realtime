import { FC, RefObject } from 'react'
import { Message } from '../types'

interface Props {
  messages: Message[]
  chatboxRef: RefObject<any>
}

const Chatbox: FC<Props> = ({ messages, chatboxRef }) => {
  return (
    <div className="flex flex-col rounded-md break-all max-h-[235px] overflow-y-scroll">
      <div
        className="space-y-1 py-2 px-4 w-[400px]"
        style={{ backgroundColor: 'rgba(0, 207, 144, 0.05)' }}
      >
        {messages.length === 0 && (
          <div className="flex items-center justify-center space-x-1 text-scale-1200 text-sm opacity-75">
            <span>Hit Enter</span>
            <code className="bg-scale-1100 text-scale-100 px-1 h-4 rounded flex items-center justify-center">
              ↩
            </code>
            <span>to start chatting 🥳</span>
          </div>
        )}
        {messages.map((message: any) => (
          <p key={message.id} className="text-scale-1200 text-sm whitespace-pre-line">
            {message.message}
          </p>
        ))}
        <div ref={chatboxRef} />
      </div>
    </div>
  )
}

export default Chatbox
