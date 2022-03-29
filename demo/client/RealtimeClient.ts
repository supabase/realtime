import { RealtimeClient, RealtimeSubscription, RealtimePresence } from '@supabase/realtime-js'

enum CHANNEL_EVENTS {
  close = 'phx_close',
  error = 'phx_error',
  join = 'phx_join',
  reply = 'phx_reply',
  leave = 'phx_leave',
  access_token = 'access_token',
}

export default class RealtimeClientV2 extends RealtimeClient {
  constructor(endPoint: string, options?: { [key: string]: any }) {
    super(endPoint, options)
  }

  channel(topic: string, chanParams = {}) {
    const chan = new RealtimeSubscriptionV2(topic, chanParams, this)

    chan.presence.onJoin((key, currentPresences, newPresences) => {
      chan.trigger('presence', {
        event: 'JOIN',
        key,
        currentPresences,
        newPresences,
      })
    })

    chan.presence.onLeave((key, currentPresences, leftPresences) => {
      chan.trigger('presence', {
        event: 'LEAVE',
        key,
        currentPresences,
        leftPresences,
      })
    })

    chan.presence.onSync(() => {
      chan.trigger('presence', { event: 'SYNC' })
    })

    this.channels.push(chan)
    return chan
  }
}

export class RealtimeSubscriptionV2 extends RealtimeSubscription {
  presence: RealtimePresence

  constructor(topic: string, params: { [key: string]: any }, socket: RealtimeClientV2) {
    super(topic, params, socket)

    this.presence = new RealtimePresence(this)
  }

  list() {
    return this.presence.list()
  }

  on(type: string, callback: Function, eventFilter?: { event: string; [key: string]: any }) {
    this.bindings.push({ type, eventFilter: eventFilter ?? {}, callback })
  }

  trigger(type: string, payload?: any, ref?: string) {
    const { close, error, leave, join } = CHANNEL_EVENTS
    const events: string[] = [close, error, leave, join]
    if (ref && events.indexOf(type) >= 0 && ref !== this.joinRef()) {
      return
    }
    const handledPayload = this.onMessage(type, payload, ref)
    if (payload && !handledPayload) {
      throw 'channel onMessage callbacks must return the payload, modified or unmodified'
    }

    this.bindings
      .filter((bind) => {
        return (
          bind?.type === type &&
          (bind?.eventFilter?.event === '*' || bind?.eventFilter?.event === payload?.event)
        )
      })
      .map((bind) => bind.callback(handledPayload, ref))
  }

  send(payload: { type: string; [key: string]: any }) {
    const push = this.push(payload.type as any, payload)

    return new Promise((resolve) => {
      push.receive('ok', () => resolve('ok'))
      push.receive('timeout', () => resolve('timeout'))
    })
  }
}
