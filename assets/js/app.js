import "../css/app.css"
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import { RealtimeClient } from '@supabase/realtime-js';

let Hooks = {}
Hooks.Payload = {
  initRealtime(path, log_level, token) {
  
  this.realtimeSocket = new RealtimeClient(path, {
      params: { log_level: log_level, apikey: token }
      })

  this.channel = this.realtimeSocket.channel('any', { config: { broadcast: { self: true } } })

  this.channel.on("broadcast", { event: "*" }, payload => {
    let line = `<li><span>BROADCAST</span><span>${JSON.stringify(payload)}</span></li>`
    let list = document.querySelector("#plist")
    list.innerHTML = line + list.innerHTML;
  })

  this.channel.subscribe(async (status) => {
  if (status === 'SUBSCRIBED') {
    this.pushEvent("subscribed", {})
    localStorage.setItem("path", path)
    localStorage.setItem("token", token)
    localStorage.setItem("log_level", log_level)
      }
    })
  },

  sendRealtime(event, payload) {
    this.channel.send({
      type: "broadcast",
      event: event,
      payload: payload
    })
  },

  mounted() {
    let params = { 
      log_level: localStorage.getItem("log_level"), 
      token: localStorage.getItem("token"), 
      path: localStorage.getItem("path")
    }

    this.pushEvent("local_storage", params)

    this.handleEvent("connect", ({connection}) => 
      this.initRealtime(connection.path, connection.log_level, connection.token)
    )

    this.handleEvent("send_message", ({message}) => 
      this.sendRealtime(message.event, message.payload)
    )
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {hooks: Hooks, params: {_csrf_token: csrfToken}})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", info => topbar.show())
window.addEventListener("phx:page-loading-stop", info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket


