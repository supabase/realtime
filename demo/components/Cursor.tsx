import { FC } from 'react'

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
  )
}

export default Cursor
