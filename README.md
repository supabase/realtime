# Supabase Realtime

Listens to changes in a PostgreSQL Database and broadcasts them over websockets. This is the realtime server for usage with your development machine. To use in production we recommend using the hosted version found at [supabase.io](supabase.io)


- [Usage](#usage)
  - [Client](#client)
    - [Install](#install)
    - [Use](#use)
  - [Server](#server)
    - [Docker](#docker)
- [Development](#development)
  - [Prerequisites](#prerequisites)
  - [Releases](#releases)


## Usage

### Client

See [https://github.com/supabase/realtime-js](https://github.com/supabase/realtime-js) for details.

#### Install 

```sh
npm install @supabase/realtime-js
```

#### Use

```javascript
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
  realtimeChannel.on('shout', payload => {
    console.log('Update received!', payload)
  })
}

```


### Server

#### Docker

The easiest way to use this is to set up a docker compose:

```sh 
# docker-compose.yml
version: '3'
services:
  realtime:
    image: supabase/realtime
    ports:
      - "4000:4000"
    environment:
    - POSTGRES_USER=postgres
    - POSTGRES_PASSWORD=postgres
    - POSTGRES_DB=postgres
    - POSTGRES_HOST=localhost
    - POSTGRES_PORT=5432
```

Then run:

```sh
docker-compose up     # Run in foreground on port 4000
docker-compose up -d  # Run in background on port 4000
docker-compose down   # Tear down
```



## Development

### Prerequisites

- Install Docker
- Install Elixir and Phoenix

Then run:

```sh
docker-compose up   # start the database (on port 6543 to avoid PG conflicts)
mix phx.server      # start the elixir app
```

### Releases

- **Docker** - Builds directly from Github