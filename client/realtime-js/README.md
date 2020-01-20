# Realtime Client
A simple wrapper over [phoenix-channels](github.com/mcampa/phoenix-client). This allows you to pass absolute URLs with query parameters appended to it.

This is a skin of a Node.js client. If you need a client for the browser use [phoenix](https://www.npmjs.com/package/phoenix)

# Usage
This uses the same API as the original [phoenix](https://www.npmjs.com/package/phoenix) except that it needs an absolute url
```javascript
const { Socket } = require('phoenix-channels')

let socket = new Socket("ws://example.com/socket")

socket.connect()

// Now that you are connected, you can join channels with a topic:
let channel = socket.channel("room:lobby", {})
channel.join()
  .receive("ok", resp => { console.log("Joined successfully", resp) })
  .receive("error", resp => { console.log("Unable to join", resp) })
```

`Presence` is also available

# Authors
Node.js client was made by Mario Campa of [phoenix-channels](github.com/mcampa/phoenix-client).

API was made by authors of the [Phoenix Framework](http://www.phoenixframework.org/)
- see their website for complete list of authors.

# License

License is the same as [phoenix-channels](github.com/mcampa/phoenix-client) and [Phoenix Framework](http://www.phoenixframework.org/) (MIT).