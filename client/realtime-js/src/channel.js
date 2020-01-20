const { CHANNEL_EVENTS, CHANNEL_STATES } = require('./constants')
const Push = require('./push')
const Timer = require('./timer')

class Channel {
  constructor(topic, params, socket) {
    this.state       = CHANNEL_STATES.closed
    this.topic       = topic
    this.params      = params || {}
    this.socket      = socket
    this.bindings    = []
    this.timeout     = this.socket.timeout
    this.joinedOnce  = false
    this.joinPush    = new Push(this, CHANNEL_EVENTS.join, this.params, this.timeout)
    this.pushBuffer  = []
    this.rejoinTimer  = new Timer(
      () => this.rejoinUntilConnected(),
      this.socket.reconnectAfterMs
    )
    this.joinPush.receive("ok", () => {
      this.state = CHANNEL_STATES.joined
      this.rejoinTimer.reset()
      this.pushBuffer.forEach( pushEvent => pushEvent.send() )
      this.pushBuffer = []
    })
    this.onClose( () => {
      this.rejoinTimer.reset()
      this.socket.log("channel", `close ${this.topic} ${this.joinRef()}`)
      this.state = CHANNEL_STATES.closed
      this.socket.remove(this)
    })
    this.onError( reason => { if(this.isLeaving() || this.isClosed()){ return }
      this.socket.log("channel", `error ${this.topic}`, reason)
      this.state = CHANNEL_STATES.errored
      this.rejoinTimer.scheduleTimeout()
    })
    this.joinPush.receive("timeout", () => { if(!this.isJoining()){ return }
      this.socket.log("channel", `timeout ${this.topic}`, this.joinPush.timeout)
      this.state = CHANNEL_STATES.errored
      this.rejoinTimer.scheduleTimeout()
    })
    this.on(CHANNEL_EVENTS.reply, (payload, ref) => {
      this.trigger(this.replyEventName(ref), payload)
    })
  }

  rejoinUntilConnected(){
    this.rejoinTimer.scheduleTimeout()
    if(this.socket.isConnected()){
      this.rejoin()
    }
  }

  join(timeout = this.timeout){
    if(this.joinedOnce){
      throw(`tried to join multiple times. 'join' can only be called a single time per channel instance`)
    } else {
      this.joinedOnce = true
      this.rejoin(timeout)
      return this.joinPush
    }
  }

  onClose(callback){ this.on(CHANNEL_EVENTS.close, callback) }

  onError(callback){
    this.on(CHANNEL_EVENTS.error, reason => callback(reason) )
  }

  on(event, callback){ this.bindings.push({event, callback}) }

  off(event){ this.bindings = this.bindings.filter( bind => bind.event !== event ) }

  canPush(){ return this.socket.isConnected() && this.isJoined() }

  push(event, payload, timeout = this.timeout){
    if(!this.joinedOnce){
      throw(`tried to push '${event}' to '${this.topic}' before joining. Use channel.join() before pushing events`)
    }
    let pushEvent = new Push(this, event, payload, timeout)
    if(this.canPush()){
      pushEvent.send()
    } else {
      pushEvent.startTimeout()
      this.pushBuffer.push(pushEvent)
    }

    return pushEvent
  }

  // Leaves the channel
  //
  // Unsubscribes from server events, and
  // instructs channel to terminate on server
  //
  // Triggers onClose() hooks
  //
  // To receive leave acknowledgements, use the a `receive`
  // hook to bind to the server ack, ie:
  //
  //     channel.leave().receive("ok", () => alert("left!") )
  //
  leave(timeout = this.timeout){
    this.state = CHANNEL_STATES.leaving
    let onClose = () => {
      this.socket.log("channel", `leave ${this.topic}`)
      this.trigger(CHANNEL_EVENTS.close, "leave", this.joinRef())
    }
    let leavePush = new Push(this, CHANNEL_EVENTS.leave, {}, timeout)
    leavePush.receive("ok", () => onClose() )
             .receive("timeout", () => onClose() )
    leavePush.send()
    if(!this.canPush()){ leavePush.trigger("ok", {}) }

    return leavePush
  }

  // Overridable message hook
  //
  // Receives all events for specialized message handling
  // before dispatching to the channel callbacks.
  //
  // Must return the payload, modified or unmodified
  onMessage(event, payload, ref){ return payload }

  // private

  isMember(topic){ return this.topic === topic }

  joinRef(){ return this.joinPush.ref }

  sendJoin(timeout){
    this.state = CHANNEL_STATES.joining
    this.joinPush.resend(timeout)
  }

  rejoin(timeout = this.timeout){ if(this.isLeaving()){ return }
    this.sendJoin(timeout)
  }

  trigger(event, payload, ref){
    let {close, error, leave, join} = CHANNEL_EVENTS
    if(ref && [close, error, leave, join].indexOf(event) >= 0 && ref !== this.joinRef()){
      return
    }
    let handledPayload = this.onMessage(event, payload, ref)
    if(payload && !handledPayload){ throw("channel onMessage callbacks must return the payload, modified or unmodified") }

    this.bindings.filter( bind => bind.event === event)
                 .map( bind => bind.callback(handledPayload, ref))
  }

  replyEventName(ref){ return `chan_reply_${ref}` }

  isClosed() { return this.state === CHANNEL_STATES.closed }
  isErrored(){ return this.state === CHANNEL_STATES.errored }
  isJoined() { return this.state === CHANNEL_STATES.joined }
  isJoining(){ return this.state === CHANNEL_STATES.joining }
  isLeaving(){ return this.state === CHANNEL_STATES.leaving }
}

module.exports = Channel