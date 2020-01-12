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

var socket = new Socket(process.env.SOCKET_URL)
socket.connect()

// Listen to all changes in the database
var allChanges = this.socket.channel('*')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

// Listen to all changes from the 'public' schema
var allChanges = this.socket.channel('public')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

// Listen to all changes from the 'users' table in the 'public' schema
var allChanges = this.socket.channel('public:users')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

```

## Contributing

We welcome any issues, pull requests, and feedback. 

## License

This repo is liscenced under Apache 2.0.

## Credits

- [https://github.com/cainophile/cainophile](https://github.com/cainophile/cainophile) - A lot of this implementation leveraged the work already done on Canophile.
