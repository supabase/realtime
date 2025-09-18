import { cn } from '@/lib/utils'
import { MousePointer2 } from 'lucide-react'

export const Cursor = ({
  className,
  style,
  color,
}: {
  className?: string
  style?: React.CSSProperties
  color: string
}) => {
  return (
    <div className={cn('pointer-events-none', className)} style={style}>
      <MousePointer2 color={color} fill={color} size={30} />
    </div>
  )
}
