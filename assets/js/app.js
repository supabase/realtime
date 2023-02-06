import "../css/app.css"
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import { RealtimeClient } from '@supabase/realtime-js';

// LiveView is managing this page because we have Phoenix running
// We're using LiveView to handle the Realtime client via LiveView Hooks

let Hooks = {}
Hooks.payload = {
  initRealtime(channelName, path, log_level, token, schema, table) {
  // Instantiate our client with the Realtime server and params to connect with
  this.realtimeSocket = new RealtimeClient(path, {
      params: { log_level: log_level, apikey: token }
      })

  // Join the Channel 'any'
  // Channels can be named anything
  // All clients on the same Channel will get messages sent to that Channel
  this.channel = this.realtimeSocket.channel(channelName, { config: { broadcast: { self: true } } })

  // Hack to confirm Postgres is subscribed
  // Need to add 'extension' key in the 'payload'
  this.channel.on("system", {}, payload => {
    if (payload.extension === 'postgres_changes' && payload.status === 'ok') {
          this.pushEventTo("#conn_info", "postgres_subscribed", {})
        }
    let ts = new Date();    
    let line = 
    `<tr class="bg-white border-b hover:bg-gray-50">
      <td class="py-4 px-6">SYSTEM</td>
      <td class="py-4 px-6">${ts.toISOString()}</td>
      <td class="py-4 px-6">${JSON.stringify(payload)}</td>
    </tr>`
    let list = document.querySelector("#plist")
    list.innerHTML = line + list.innerHTML;
    })

  // Listen for all (`*`) `broadcast` events
  // The event name can by anything
  // Match on specific event names to filter for only those types of events and do something with them
  this.channel.on("broadcast", { event: "*" }, payload => {
    let ts = new Date();
    let line = 
      `<tr class="bg-white border-b hover:bg-gray-50">
        <td class="py-4 px-6">BROADCAST</td>
        <td class="py-4 px-6">${ts.toISOString()}</td>
        <td class="py-4 px-6">${JSON.stringify(payload)}</td>
      </tr>`
    let list = document.querySelector("#plist")
    list.innerHTML = line + list.innerHTML;
  })

  // Listen for all (`*`) `presence` events
  this.channel.on("presence", { event: "*" }, payload => {
    this.pushEventTo("#conn_info", "presence_subscribed", {})
    let ts = new Date();
    let line =
      `<tr class="bg-white border-b hover:bg-gray-50">
        <td class="py-4 px-6">PRESENCE</td>
        <td class="py-4 px-6">${ts.toISOString()}</td>
        <td class="py-4 px-6">${JSON.stringify(payload)}</td>
      </tr>`
    let list = document.querySelector("#plist")
    list.innerHTML = line + list.innerHTML;
  })

  // Listen for all (`*`) `postgres_changes` events on tables in the `public` schema
  this.channel.on("postgres_changes", { event: "*", schema: schema, table: table }, payload => {
    let ts = performance.now() + performance.timeOrigin
    let iso_ts = new Date()
    let payload_ts = Date.parse(payload.commit_timestamp)
    let latency = ts - payload_ts
    let line = 
      `<tr class="bg-white border-b hover:bg-gray-50">
        <td class="py-4 px-6">POSTGRES</td>
        <td class="py-4 px-6">${iso_ts.toISOString()}</td>
        <td class="py-4 px-6">
          <div class="pb-3">${JSON.stringify(payload)}</div>
          <div class="pt-3 border-t hover:bg-gray-50">Latency: ${latency.toFixed(1)} ms</div>
        </td>
      </tr>`
    let list = document.querySelector("#plist")
    list.innerHTML = line + list.innerHTML;
  })

  // Finally, subscribe to the Channel we just setup
  this.channel.subscribe(async (status) => {
  if (status === 'SUBSCRIBED') {
    console.log(`Realtime Channel status: ${status}`)

    // Let LiveView know we connected so we can update the button text
    this.pushEventTo("#conn_info", "broadcast_subscribed", { path: path})
    
    // Save params to local storage if `SUBSCRIBED`
    localStorage.setItem("path", path)
    localStorage.setItem("token", token)
    localStorage.setItem("log_level", log_level)
    localStorage.setItem("channel", channelName)
    localStorage.setItem("schema", schema)
    localStorage.setItem("table", table)

    // Initiate Presence for a connected user
    // Now when a new user connects and sends a `TRACK` message all clients will receive a message like: 
    // {
    //     "event":"join",
    //     "key":"2b88be54-3b41-11ed-9887-1a9e1a785cf8",
    //     "currentPresences":[
    //     
    //     ],
    //     "newPresences":[
    //        {
    //           "name":"realtime_presence_55",
    //           "t":1968.1000000238419,
    //           "presence_ref":"Fxd_ZWlhIIfuIwlD"
    //        }
    //     ]
    // }
    //
    // And when `TRACK`ed users leave we'll receive an event like:
    // 
    // {
    //     "event":"leave",
    //     "key":"2b88be54-3b41-11ed-9887-1a9e1a785cf8",
    //     "currentPresences":[
    //     
    //     ],
    //     "leftPresences":[
    //        {
    //           "name":"realtime_presence_55",
    //           "t":1968.1000000238419,
    //           "presence_ref":"Fxd_ZWlhIIfuIwlD"
    //        }
    //     ]
    // }
    const name = 'user_name_' + Math.floor(Math.random() * 100)
    this.channel.send(
      {
        type: 'presence',
        event: 'TRACK',
        payload: { name: name, t: performance.now() },
      })
      } else {
        console.log(`Realtime Channel status: ${status}`)
      }
    })
  },

  sendRealtime(event, payload) {
    // Send a `broadcast` message over the Channel
    // All connected clients will receive this message if they're subscribed 
    // to `broadcast` events and matching on the `event` name or using `*` to match all event names
    this.channel.send({
      type: "broadcast",
      event: event,
      payload: payload
    })
  },

  disconnectRealtime() {
    // Send a `broadcast` message over the Channel
    // All connected clients will receive this message if they're subscribed 
    // to `broadcast` events and matching on the `event` name or using `*` to match all event names
    this.channel.unsubscribe()
  },

  clearLocalStorage() {
    localStorage.clear()
  },

  mounted() {
    let params = { 
      log_level: localStorage.getItem("log_level"), 
      token: localStorage.getItem("token"), 
      path: localStorage.getItem("path"),
      channel: localStorage.getItem("channel"),
      schema: localStorage.getItem("schema"),
      table: localStorage.getItem("table")
    }

    this.pushEventTo("#conn_form", "local_storage", params)

    this.handleEvent("connect", ({connection}) => 
      this.initRealtime(connection.channel, connection.path, connection.log_level, connection.token, connection.schema, connection.table)
    )

    this.handleEvent("send_message", ({message}) => 
      this.sendRealtime(message.event, message.payload)
    )

    this.handleEvent("disconnect", ({}) => 
      this.disconnectRealtime()
    )

    this.handleEvent("clear_local_storage", ({}) => 
      this.clearLocalStorage()
    )

    
  }
}

Hooks.latency = {
  mounted() {
    this.handleEvent("ping", (params) => 
      this.pong(params)
    )
  },

  pong(params) {
    this.pushEventTo("#ping", "pong", params)
  },
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {hooks: Hooks, params: {_csrf_token: csrfToken}})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", info => topbar.show())
window.addEventListener("phx:page-loading-stop", info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket


