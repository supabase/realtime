# Supabase Realtime

Listens to changes in a PostgreSQL Database and broadcasts them over websockets.

## Status

> Status: ALPHA

This repo is still under heavy development and the documentation is still evolving. You're welcome to try it, but expect some breaking changes.

## Docs 

Docs are a work in progress. Start here: [https://supabase.io/docs/realtime/introduction]

## Example

```js
import { Socket } = '@supabase/realtime-js'

var API_SOCKET = process.env.SOCKET_URL
var socket = new Socket(API_SOCKET)
var realtimeChannel = this.socket.channel('realtime')

socket.connect()
if (realtimeChannel.state !== 'joined') {
  realtimeChannel
    .join()
    .receive('ok', resp => console.log('Joined successfully', resp))
    .receive('error', resp => console.log('Unable to join', resp))
    .receive('timeout', () => console.log('Networking issue. Still waiting...'))

  // Listen to all changes in the database
  realtimeChannel.on('*', payload => {
    console.log('Update received!', payload)
  })
  
  // Listen to all changes from the 'public' schema
  realtimeChannel.on('public', payload => {
    console.log('Update received!', payload)
  })
  
  // Listen to all changes from the 'users' table in the 'public' schema
  realtimeChannel.on('public:users', payload => {
    console.log('Update received!', payload)
  })
}

```

## Contributing

We welcome any issues, pull requests, and feedback. See [https://supabase.io/docs/-/contributing](https://supabase.io/docs/-/contributing) for more details.

## License

This repo is liscenced under Apache 2.0.

## Credits

- [https://github.com/cainophile/cainophile](https://github.com/cainophile/cainophile) - A lot of this implementation leveraged the work already done on Canophile.
