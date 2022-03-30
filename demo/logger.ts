import pino from 'pino'
import { createPinoBrowserSend, createWriteStream } from 'pino-logflare'

const LOGFLARE_API_KEY = process.env.NEXT_PUBLIC_LOGFLARE_API_KEY
const LOGFLARE_SOURCE_ID = process.env.NEXT_PUBLIC_LOGFLARE_SOURCE_ID

const logger = () => {
  if (!LOGFLARE_API_KEY || !LOGFLARE_SOURCE_ID) {
    return
  }

  const send = createPinoBrowserSend({
    apiKey: LOGFLARE_API_KEY!,
    sourceToken: LOGFLARE_SOURCE_ID!,
  })

  const stream = createWriteStream({
    apiKey: LOGFLARE_API_KEY!,
    sourceToken: LOGFLARE_SOURCE_ID!,
  })

  return pino(
    {
      browser: {
        transmit: { send },
      },
    },
    stream
  )
}

export default logger()
