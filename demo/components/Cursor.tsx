import { FC } from 'react'
import { IconMousePointer } from '@supabase/ui'

interface Props {
  x: number | null
  y: number | null
  color: string
}

const Cursor: FC<Props> = ({ x, y, color }) => {
  if (!x || !y || !color) {
    return null
  }

  return (
    <IconMousePointer
      style={{ color, transform: `translateX(${x}px) translateY(${y}px)` }}
      className="absolute top-0 left-0 transform"
      size={24}
      strokeWidth={2}
    />
  )
}

export default Cursor
