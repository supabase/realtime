import { NextResponse } from 'next/server'
import type { NextFetchEvent, NextRequest } from 'next/server'

export function middleware(req: NextRequest, ev: NextFetchEvent) {
  let url = req.nextUrl

  if (url.pathname === '/') {
    url = url.clone()
    url.pathname = '/redirect'
    return NextResponse.rewrite(url)
  }
}
