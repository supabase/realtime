export interface Coordinates {
  x: number | undefined
  y: number | undefined
}

export interface DatabaseChange {
  columns: {
    name: string
    type: string
  }[]
  commit_timestamp: string
  errors: null | string[]
  record: { [key: string]: any }
  schema: string
  table: string
  type: 'INSERT'
}

export interface Message {
  id: number
  user_id: string
  message: string
}

export interface Payload<T> {
  type: string
  event: string
  payload: T
  key?: string
}

export interface User extends Coordinates {
  color: string
  hue: string
  isTyping?: boolean
  message?: string
}
