# Realtime

Presence and ephemeral state.

# Local Setup

Create `config.yml` in root directory and copy/paste the following:

```yml
endpoint_port: 4000
db_repo:
  - hostname: "localhost"
    username: "postgres"
    password: "postgres"
    database: "postgres"
    pool_size: 3
    port: 5432
```

Open up three different terminal windows and run the following sequentially:

1. In the first terminal, run `make start.dbs`.
2. In the second terminal, run `make dev`.
3. In the third terminal, run `make seed`.

### Note

- Generate a JWT from `jwt_secret` column on `tenants` table for tenant `dev_tenant`.

## Motivation

Software is becoming more collaborative. Often the data that we need to share is ephemeral, meaning that it doesn't need to be stored in a database. The goals for ephemeral data are different from stored data:

- Highly Available, Eventually Consistent
- Changing frequently, not persisted
- Accessible to other users
- High number of connections at one time
- Usually requires presence information - knowing who is online


## Usage

Install the client library:

```bash
npm install phoenix
```

Running in your browser

```js

import { Socket, Presence } from "phoenix";

let socket = new Socket("/socket", {
  params: { user_id: 'f752eab0-c6d3-4c34-abb3-5384ee4dffd4' },
});

let roomName = 'room:my-awesome-room'
let room = socket.channel(roomName, {})
let presence = new Presence(channel)

presence.onSync(() => {
  let state = {};
  let usersOnline = 0

  // Loop through all the online users
  presence.list((userId, { metas: [firstUser, ...otherUsers] }) => {
    usersOnline =  otherUsers.length + 1;
    state[userId] = firstUser
  });

  // Do something with the state
  console.log(state)
})

// Connect
socket.connect()
room.join()


// Example of how you would use it for a 
// typing indicator:
let textbox = document.querySelector("input");
textbox.oninput = function () {
  console.log(textbox.value);
  room.push("broadcast", { typing: true });
};

```

### Server

To start your Phoenix server:

  * Install dependencies with `mix deps.get`
  * Start Phoenix endpoint with `mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).


### Deploy

fly deploy