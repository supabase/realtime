import { NextApiRequest, NextApiResponse } from 'next'

const LOGFLARE_API_KEY = process.env.LOGFLARE_API_KEY || ''
const LOGFLARE_SOURCE_ID = process.env.LOGFLARE_SOURCE_ID || ''

const recordLogs = async (req: NextApiRequest, res: NextApiResponse) => {
  if (!LOGFLARE_API_KEY || !LOGFLARE_SOURCE_ID) {
    return res.status(400).json('Logs are not being recorded')
  }
  if (req.method !== 'POST') {
    return res.status(400).json('Only POST methods are supported')
  }

  const body = await req.body

  try {
    await fetch(`https://api.logflare.app/api/logs?source=${LOGFLARE_SOURCE_ID}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-KEY': `${LOGFLARE_API_KEY}`,
      },
      body: JSON.stringify(body),
    })
    res.json('ok')
  } catch (e) {
    console.error(JSON.stringify(e))
  }
}

export default recordLogs
