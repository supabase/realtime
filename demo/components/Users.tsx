import { FC } from 'react'
import { User } from '../types'

interface Props {
  users: Record<string, User>
}

const Users: FC<Props> = ({ users }) => {
  return (
    <div className="relative">
      {Object.entries(users).map(([userId, userData], idx) => {
        return (
          <div className="relative">
            <div
              key={userId}
              className={[
                'transition-all absolute right-0 h-8 w-8 bg-scale-1200 rounded-full bg-center bg-[length:50%_50%]',
                'bg-no-repeat shadow-md flex items-center justify-center',
              ].join(' ')}
              style={{
                border: `1px solid ${userData.hue}`,
                background: userData.color,
                transform: `translateX(${Math.abs(idx - (Object.keys(users).length - 1)) * -20}px)`,
              }}
            >
              <div
                style={{ background: userData.color }}
                className="left-0 top-0 absolute w-8 h-8 animate-ping rounded-full animation-"
              ></div>
            </div>
          </div>
        )
      })}
    </div>
  )
}

export default Users
