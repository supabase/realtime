import { FC, FormEvent, useEffect, useRef, useState } from 'react'

interface Props {
  x: number | null
  y: number | null
  color: string
  message: string
  isTyping?: boolean
  isLocalClient?: boolean
  onUpdateMessage?: (message: string) => void
}

const MAX_MESSAGE_LENGTH = 20

const Cursor: FC<Props> = ({
  x,
  y,
  color,
  message,
  isTyping,
  isLocalClient,
  onUpdateMessage = () => {},
}) => {
  // Don't show cursor for the local client
  const _isLocalClient = !x || !y || isLocalClient
  const inputRef = useRef() as any
  const timeoutRef = useRef() as any

  const [hideInput, setHideInput] = useState(false)
  const [showMessageBubble, setShowMessageBubble] = useState(false)

  // [Joshen] This is some really bad way of writing conditionals 🙈
  // Ideally i'd refactor them to be more concise and less error-prone
  // but just gonna focus on shipping something working first
  useEffect(() => {
    if (isTyping) {
      setShowMessageBubble(true)
      if (isLocalClient) {
        setHideInput(false)
      }
    } else if (!isTyping && !message && isLocalClient) {
      setShowMessageBubble(false)
    }

    // Logic specifically for local client
    if (isTyping && isLocalClient && inputRef.current) {
      inputRef.current.focus()
    }

    if (!isTyping && message && isLocalClient) {
      setHideInput(true)
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current)
      }
      const timeoutId = setTimeout(() => {
        setHideInput(false)
        setShowMessageBubble(false)
      }, 2000)
      timeoutRef.current = timeoutId
    }

    // Logic specifically for non-local clients
    if (isTyping && !isLocalClient) {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current)
      }
    }

    if (!isTyping && !message && !isLocalClient) {
      setShowMessageBubble(false)
    }

    if (message && !isLocalClient) {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current)
      }
      const timeoutId = setTimeout(() => {
        setShowMessageBubble(false)
      }, 2000)
      timeoutRef.current = timeoutId
    }
  }, [isTyping, message, inputRef])

  return (
    <>
      {!_isLocalClient && (
        <svg
          width="18"
          height="24"
          viewBox="0 0 18 24"
          fill="none"
          className="absolute top-0 left-0 transform transition"
          style={{ color, transform: `translateX(${x}px) translateY(${y}px)` }}
          xmlns="http://www.w3.org/2000/svg"
        >
          <path
            d="M2.717 2.22918L15.9831 15.8743C16.5994 16.5083 16.1503 17.5714 15.2661 17.5714H9.35976C8.59988 17.5714 7.86831 17.8598 7.3128 18.3783L2.68232 22.7C2.0431 23.2966 1 22.8434 1 21.969V2.92626C1 2.02855 2.09122 1.58553 2.717 2.22918Z"
            fill={color}
            stroke="white"
            strokeWidth="2"
          />
        </svg>
      )}
      <div
        className={`absolute top-0 left-0 transform transition py-2 rounded-full shadow-md ${
          showMessageBubble ? 'opacity-100' : 'opacity-0'
        } flex items-center justify-between ${_isLocalClient ? 'px-6' : 'px-4'} ${
          _isLocalClient && !hideInput ? 'w-[280px]' : ''
        }`}
        style={{
          backgroundColor: color || '#3ECF8E',
          transform: `translateX(${(x || 0) + 20}px) translateY(${(y || 0) + 20}px)`,
        }}
      >
        {_isLocalClient && !hideInput ? (
          <>
            <input
              ref={inputRef}
              value={message}
              className="outline-none bg-transparent border-none"
              onChange={(e: FormEvent<HTMLInputElement>) => {
                const text = e.currentTarget.value
                if (text.length <= MAX_MESSAGE_LENGTH) onUpdateMessage(e.currentTarget.value)
              }}
            />
            <p className="text-scale-600 text-sm">
              {message.length}/{MAX_MESSAGE_LENGTH}
            </p>
          </>
        ) : message.length ? (
          <div>{message}</div>
        ) : (
          <div className="space-x-1">
            <span>•</span>
            <span>•</span>
            <span>•</span>
          </div>
        )}
      </div>
    </>
  )
}

export default Cursor
