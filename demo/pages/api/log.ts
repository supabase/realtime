import { NextApiRequest, NextApiResponse } from 'next'
import pino from 'pino'
import { createPinoBrowserSend, createWriteStream } from 'pino-logflare'

const LOGFLARE_API_KEY = process.env.LOGFLARE_API_KEY
const LOGFLARE_SOURCE_ID = process.env.LOGFLARE_SOURCE_ID

const send = createPinoBrowserSend({
  apiKey: LOGFLARE_API_KEY!,
  sourceToken: LOGFLARE_SOURCE_ID!,
})

const stream = createWriteStream({
  apiKey: LOGFLARE_API_KEY!,
  sourceToken: LOGFLARE_SOURCE_ID!,
})

const logger = pino(
  {
    browser: {
      transmit: { send },
    },
  },
  stream
)

const recordLogs = async (req: NextApiRequest, res: NextApiResponse) => {
  if (!LOGFLARE_API_KEY || !LOGFLARE_SOURCE_ID) {
    return res.status(400).json('Logs are not being recorded')
  }
  if (req.method !== 'POST') {
    return res.status(400).json('Only POST methods are supported')
  }
  const { message } = await req.body
  logger.info(message)
  res.json('ok')
}

export default recordLogs
