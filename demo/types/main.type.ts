export interface User {
  x: number | null
  y: number | null
  color: string
  isTyping?: boolean
  message?: string
}

export interface Message {
  id?: string
  user_id?: string
  room_id?: string
  message: string
  created_at: string
}

export interface Coordinate {
  x: number
  y: number
}
