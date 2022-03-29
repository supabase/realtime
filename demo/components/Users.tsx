import { FC } from 'react'

interface Props {
  users: any
}

const Users: FC<Props> = ({ users }) => {
  return (
    <div className="relative">
      {Object.entries(users).map(([userId, userData], idx) => {
        return (
          <div
            key={userId}
            className={[
              'absolute right-0 h-10 w-10 bg-scale-1200 rounded-full bg-center bg-[length:50%_50%]',
              'bg-no-repeat shadow-md flex items-center justify-center border-2 border-scale-1200',
            ].join(' ')}
            style={{
              background: (userData as { color: string }).color,
              transform: `translateX(${Math.abs(idx - (Object.keys(users).length - 1)) * -20}px)`,
            }}
          ></div>
        )
      })}
    </div>
  )
}

export default Users
