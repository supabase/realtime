
class Push {

  // Initializes the Push
  //
  // channel - The Channel
  // event - The event, for example `"phx_join"`
  // payload - The payload, for example `{user_id: 123}`
  // timeout - The push timeout in milliseconds
  //
  constructor(channel, event, payload, timeout){
    this.channel      = channel
    this.event        = event
    this.payload      = payload || {}
    this.receivedResp = null
    this.timeout      = timeout
    this.timeoutTimer = null
    this.recHooks     = []
    this.sent         = false
  }

  resend(timeout){
    this.timeout = timeout
    this.cancelRefEvent()
    this.ref          = null
    this.refEvent     = null
    this.receivedResp = null
    this.sent         = false
    this.send()
  }

  send(){ if(this.hasReceived("timeout")){ return }
    this.startTimeout()
    this.sent = true
    this.channel.socket.push({
      topic: this.channel.topic,
      event: this.event,
      payload: this.payload,
      ref: this.ref,
    })
  }

  receive(status, callback){
    if(this.hasReceived(status)){
      callback(this.receivedResp.response)
    }

    this.recHooks.push({status, callback})
    return this
  }


  // private

  matchReceive({status, response, ref}){
    this.recHooks.filter( h => h.status === status )
                 .forEach( h => h.callback(response) )
  }

  cancelRefEvent(){ if(!this.refEvent){ return }
    this.channel.off(this.refEvent)
  }

  cancelTimeout(){
    clearTimeout(this.timeoutTimer)
    this.timeoutTimer = null
  }

  startTimeout(){ if(this.timeoutTimer){ return }
    this.ref      = this.channel.socket.makeRef()
    this.refEvent = this.channel.replyEventName(this.ref)

    this.channel.on(this.refEvent, payload => {
      this.cancelRefEvent()
      this.cancelTimeout()
      this.receivedResp = payload
      this.matchReceive(payload)
    })

    this.timeoutTimer = setTimeout(() => {
      this.trigger("timeout", {})
    }, this.timeout)
  }

  hasReceived(status){
    return this.receivedResp && this.receivedResp.status === status
  }

  trigger(status, response){
    this.channel.trigger(this.refEvent, {status, response})
  }
}

module.exports = Push