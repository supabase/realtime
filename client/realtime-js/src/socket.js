const {
  VSN,
  CHANNEL_EVENTS,
  TRANSPORTS,
  SOCKET_STATES,
  DEFAULT_TIMEOUT,
  WS_CLOSE_NORMAL ,
} = require('./constants')

const querystring = require('query-string')
const WebSocket = require('websocket').w3cwebsocket
const Timer = require('./timer')
const Channel = require('./channel')

class Socket {

  // Initializes the Socket
  //
  // endPoint - The string WebSocket endpoint, ie, "ws://example.com/socket",
  //                                               "wss://example.com"
  //                                               "/socket" (inherited host & protocol)
  // opts - Optional configuration
  //   transport - The Websocket Transport, for example WebSocket.
  //
  //   encode - The function to encode outgoing messages. Defaults to JSON:
  //
  //     (payload, callback) => callback(JSON.stringify(payload))
  //
  //   decode - The function to decode incoming messages. Defaults to JSON:
  //
  //     (payload, callback) => callback(JSON.parse(payload))
  //
  //   timeout - The default timeout in milliseconds to trigger push timeouts.
  //             Defaults `DEFAULT_TIMEOUT`
  //   heartbeatIntervalMs - The millisec interval to send a heartbeat message
  //   reconnectAfterMs - The optional function that returns the millsec
  //                      reconnect interval. Defaults to stepped backoff of:
  //
  //     function(tries){
  //       return [1000, 5000, 10000][tries - 1] || 10000
  //     }
  //
  //   logger - The optional function for specialized logging, ie:
  //     `logger: (kind, msg, data) => { console.log(`${kind}: ${msg}`, data) }
  //
  //   longpollerTimeout - The maximum timeout of a long poll AJAX request.
  //                        Defaults to 20s (double the server long poll timer).
  //
  //   params - The optional params to pass when connecting
  //
  // For IE8 support use an ES5-shim (https://github.com/es-shims/es5-shim)
  //
  constructor(endPoint, opts = {}){
    // we would want to check if the provided endPoint comes along with any
    // query parameters

    this.stateChangeCallbacks = {open: [], close: [], error: [], message: []}
    this.channels             = []
    this.sendBuffer           = []
    this.ref                  = 0
    this.timeout              = opts.timeout || DEFAULT_TIMEOUT
    this.transport            = opts.transport || WebSocket
    this.defaultEncoder       = (payload, callback) => callback(JSON.stringify(payload))
    this.defaultDecoder       = (payload, callback) => callback(JSON.parse(payload))

    this.encode = opts.encode || this.defaultEncoder
    this.decode = opts.decode || this.defaultDecoder

    this.heartbeatIntervalMs  = opts.heartbeatIntervalMs || 30000
    this.reconnectAfterMs     = opts.reconnectAfterMs || function(tries){
      return [1000, 2000, 5000, 10000][tries - 1] || 10000
    }
    this.logger               = opts.logger || function(){} // noop
    this.longpollerTimeout    = opts.longpollerTimeout || 20000
    this.params               = opts.params || {}
    this.headers              = opts.headers || {}
    this.endPoint             = `${endPoint}/${TRANSPORTS.websocket}`
    this.heartbeatTimer       = null
    this.pendingHeartbeatRef  = null
    this.reconnectTimer       = new Timer(() => {
      this.disconnect(() => this.connect())
    }, this.reconnectAfterMs)
  }

  endPointURL(){
    return this.appendParams(this.endPoint, Object.assign({}, this.params, {vsn: VSN}))
  }

  appendParams(url, params){
    if(Object.keys(params).length === 0){ return url }

    let prefix = url.match(/\?/) ? "&" : "?"
    return `${url}${prefix}${querystring.stringify(params)}`
  }

  disconnect(callback, code, reason){
    if(this.conn){
      this.conn.onclose = function(){} // noop
      if(code){ this.conn.close(code, reason || "") } else { this.conn.close() }
      this.conn = null
    }
    callback && callback()
  }

  connect(){
    if(this.conn){ return }

    this.conn = new this.transport(this.endPointURL(), [], null, this.headers)
    this.conn.timeout   = this.longpollerTimeout
    this.conn.onopen    = () => this.onConnOpen()
    this.conn.onerror   = error => this.onConnError(error)
    this.conn.onmessage = event => this.onConnMessage(event)
    this.conn.onclose   = event => this.onConnClose(event)
  }

  // Logs the message. Override `this.logger` for specialized logging. noops by default
  log(kind, msg, data){ this.logger(kind, msg, data) }

  // Registers callbacks for connection state change events
  //
  // Examples
  //
  //    socket.onError(function(error){ alert("An error occurred") })
  //
  onOpen     (callback){ this.stateChangeCallbacks.open.push(callback) }
  onClose    (callback){ this.stateChangeCallbacks.close.push(callback) }
  onError    (callback){ this.stateChangeCallbacks.error.push(callback) }
  onMessage  (callback){ this.stateChangeCallbacks.message.push(callback) }

  onConnOpen(){
    this.log("transport", `connected to ${this.endPointURL()}`)
    this.flushSendBuffer()
    this.reconnectTimer.reset()
    if(!this.conn.skipHeartbeat){
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = setInterval(() => this.sendHeartbeat(), this.heartbeatIntervalMs)
    }
    this.stateChangeCallbacks.open.forEach( callback => callback() )
  }

  onConnClose(event){
    this.log("transport", "close", event)
    this.triggerChanError()
    clearInterval(this.heartbeatTimer)
    this.reconnectTimer.scheduleTimeout()
    this.stateChangeCallbacks.close.forEach( callback => callback(event) )
  }

  onConnError(error){
    this.log("transport", error)
    this.triggerChanError()
    this.stateChangeCallbacks.error.forEach( callback => callback(error) )
  }

  triggerChanError(){
    this.channels.forEach( channel => channel.trigger(CHANNEL_EVENTS.error) )
  }

  connectionState(){
    switch(this.conn && this.conn.readyState){
      case SOCKET_STATES.connecting: return "connecting"
      case SOCKET_STATES.open:       return "open"
      case SOCKET_STATES.closing:    return "closing"
      default:                       return "closed"
    }
  }

  isConnected(){ return this.connectionState() === "open" }

  remove(channel){
    this.channels = this.channels.filter(c => c.joinRef() !== channel.joinRef())
  }

  channel(topic, chanParams = {}){
    let chan = new Channel(topic, chanParams, this)
    this.channels.push(chan)
    return chan
  }

  push(data){
    let {topic, event, payload, ref} = data
    let callback = () => {
      this.encode(data, result => {
        this.conn.send(result)
      })
    }
    this.log("push", `${topic} ${event} (${ref})`, payload)
    if(this.isConnected()){
      callback()
    }
    else {
      this.sendBuffer.push(callback)
    }
  }

  // Return the next message ref, accounting for overflows
  makeRef(){
    let newRef = this.ref + 1
    if(newRef === this.ref){ this.ref = 0 } else { this.ref = newRef }

    return this.ref.toString()
  }

  sendHeartbeat(){ if(!this.isConnected()){ return }
    if(this.pendingHeartbeatRef){
      this.pendingHeartbeatRef = null
      this.log("transport", "heartbeat timeout. Attempting to re-establish connection")
      this.conn.close(WS_CLOSE_NORMAL, "hearbeat timeout")
      return
    }
    this.pendingHeartbeatRef = this.makeRef()
    this.push({topic: "phoenix", event: "heartbeat", payload: {}, ref: this.pendingHeartbeatRef})
  }

  flushSendBuffer(){
    if(this.isConnected() && this.sendBuffer.length > 0){
      this.sendBuffer.forEach( callback => callback() )
      this.sendBuffer = []
    }
  }

  onConnMessage(rawMessage){
    this.decode(rawMessage.data, msg => {
      let {topic, event, payload, ref} = msg
      if(ref && ref === this.pendingHeartbeatRef){ this.pendingHeartbeatRef = null }

      this.log("receive", `${payload.status || ""} ${topic} ${event} ${ref && "(" + ref + ")" || ""}`, payload)
      this.channels.filter( channel => channel.isMember(topic) )
                   .forEach( channel => channel.trigger(event, payload, ref) )
      this.stateChangeCallbacks.message.forEach( callback => callback(msg) )
    })
  }
}

module.exports = Socket