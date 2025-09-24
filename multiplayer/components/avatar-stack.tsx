import { cn } from '@/lib/utils'
import { cva, type VariantProps } from 'class-variance-authority'
import * as React from 'react'

const avatarStackVariants = cva('flex -space-x-4 -space-y-4', {
  variants: {
    orientation: {
      vertical: 'flex-row',
      horizontal: 'flex-col',
    },
  },
  defaultVariants: {
    orientation: 'vertical',
  },
})

export interface AvatarStackProps
  extends React.HTMLAttributes<HTMLDivElement>,
    VariantProps<typeof avatarStackVariants> {
  avatars: { color: string }[]
}

const AvatarStack = ({
  className,
  orientation,
  avatars,
  ...props
}: AvatarStackProps) => {
  const shownAvatars = avatars

  return (
    <div
      className={cn(
        avatarStackVariants({ orientation }),
        className,
        orientation === 'horizontal' ? '-space-x-0' : '-space-y-0'
      )}
      {...props}
    >
      {shownAvatars.map(({ color }, index) => (
        <div key={index} className="relative">
          <div
            key={index}
            className={[
              'transition-all absolute right-0 h-8 w-8 bg-scale-1200 rounded-full bg-center bg-[length:50%_50%]',
              'bg-no-repeat shadow-md flex items-center justify-center',
            ].join(' ')}
            style={{ background: color }}
          >
            <div style={{ background: color }} className="w-7 h-7 animate-ping-once rounded-full" />
          </div>
        </div>
      ))}
    </div>
  )
}

export { AvatarStack, avatarStackVariants }
