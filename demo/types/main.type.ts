export interface User {
  id: string
  x: number
  y: number
  color: string
}

export interface Message {
  id?: string
  user_id?: string
  room_id?: string
  message: string
  created_at: string
}
