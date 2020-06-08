# Supabase Realtime

Listens to changes in a PostgreSQL Database and broadcasts them over websockets.

<p align="center"><kbd><img src="./examples/next-js/demo.gif" alt="Demo"/></kbd></p>


**Contents**
- [Status](#status)
- [Example](#example)
- [Introduction](#introduction)
    - [What is this?](#what-is-this)
    - [Cool, but why not just use Postgres' `NOTIFY`?](#cool-but-why-not-just-use-postgres-notify)
    - [What are the benefits?](#what-are-the-benefits)
- [Quick start](#quick-start)
- [Getting Started](#getting-started)
  - [Client](#client)
  - [Server](#server)
  - [Database set up](#database-set-up)
  - [Server set up](#server-set-up)
- [Contributing](#contributing)
- [Releases](#releases)
- [License](#license)
- [Credits](#credits)

## Status

- [x] Alpha: Under heavy development
- [x] Beta: Ready for use. But go easy on us, there may be a few kinks.
- [ ] 1.0: Use in production!

This repo is still under heavy development and the documentation is evolving. You're welcome to try it, but expect some breaking changes. Watch "releases" of this repo to receive a notifification when we are ready for Beta. And give us a star if you like it!

![Watch this repo](https://gitcdn.xyz/repo/supabase/monorepo/master/web/static/watch-repo.gif "Watch this repo")


## Example

```js
import { Socket } = '@supabase/realtime-js'

var socket = new Socket(process.env.REALTIME_URL)
socket.connect()

// Listen to only INSERTS on the 'users' table in the 'public' schema
var allChanges = this.socket.channel('realtime:public:users')
  .join()
  .on('INSERT', payload => { console.log('Update received!', payload) })

// Listen to all changes from the 'public' schema
var allChanges = this.socket.channel('realtime:public')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

// Listen to all changes in the database
let allChanges = this.socket.channel('realtime:*')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

```

## Introduction

#### What is this?

This is an Elixir server (Phoenix) that allows you to listen to changes in your database via websockets.

It works like this:

1. the Phoenix server listens to PostgreSQL's replication functionality (using Postgres' logical decoding)
2. it converts the byte stream into JSON
3. it then broadcasts over websockets. 
  
#### Cool, but why not just use Postgres' `NOTIFY`?

A few reasons:

1. You don't have to set up triggers on every table
2. NOTIFY has a payload limit of 8000 bytes and will fail for anything larger. The usual solution is to send and ID then fetch the record, but that's heavy on the database
3. This server consumes one connection to the database, then you can connect many clients to this server. Easier on your database, and to scale up you just add realtime servers

#### What are the benefits?

1. The beauty of listening to the replication functionality is that you can make changes to your database from anywhere - your API, directly in the DB, via a console etc - and you will still receive the changes via websockets. 
2. Decoupling. For example, if you want to send a new slack message every time someone makes a new purchase you might build that funcitonality directly into your API. This allows you to decouple your async functionality from your API.
3. This is built with Phoenix, an [extremely scalable Elixir framework](https://www.phoenixframework.org/blog/the-road-to-2-million-websocket-connections)


## Quick start

If you just want to start it up and see it in action: 

1. Run `docker-compose up`
2. Visit `http://localhost:3000` (be patient, node_modules will need to install)

## Getting Started

### Client

Install the client library

```sh
npm install --save @supabase/realtime-js
```

Set up the socket

```js
import { Socket } = '@supabase/realtime-js'

const REALTIME_URL = process.env.REALTIME_URL || 'http://localhost:4000'
var socket = new Socket(REALTIME_URL) 
socket.connect()
```

You can listen to these events on each table:

```js
const EVENTS = {
  EVERYTHING: '*',
  INSERT: 'INSERT',
  UPDATE: 'UPDATE',
  DELETE: 'DELETE'
}
```

Example 1: Listen to all INSERTS, on your `users` table

```js
var allChanges = this.socket.channel('realtime:public:users')
  .join()
  .on(EVENTS.INSERT, payload => { console.log('Record inserted!', payload) })
```

Example 2: Listen to all UPDATES in the `public` schema

```js
var allChanges = this.socket.channel('realtime:public')
  .join()
  .on(EVENTS.UPDATE, payload => { console.log('Update received!', payload) })

```

Example 3: Listen to all INSERTS, UPDATES, and DELETES, in all schemas

```js
let allChanges = this.socket.channel('realtime:*')
  .join()
  .on(EVENTS.EVERYTHING, payload => { console.log('Update received!', payload) })
```

### Server

### Database set up

There are a some requirements for your database

1. It must be Postgres 10+ as it uses logical replication
2. Set up your DB for replication
   1. it must have the `wal_level` set to logical. You can check this by running `SHOW wal_level;`. To set the `wal_level`, you can call `ALTER SYSTEM SET wal_level = logical;`
   2. You must set `max_replication_slots` to at least 1: `ALTER SYSTEM SET max_replication_slots = 5;`
3. Create a `PUBLICATION` for this server to listen to: `CREATE PUBLICATION supabase_realtime FOR ALL TABLES;`
4. [OPTIONAL] If you want to recieve the old record (previous values) on UDPATE and DELETE, you can set the `REPLICA IDENTITY` to `FULL` like this: `ALTER TABLE your_table REPLICA IDENTITY FULL;`. This has to be set for each table unfortunately.


### Server set up

The easiest way to get started is just to use our docker image. We will add more deployment methods soon.

```sh
# Update the environment variables to point to your own database
docker run \
  -e DB_HOST='docker.for.mac.host.internal' \
  -e DB_NAME='postgres' \
  -e DB_USER='postgres' \
  -e DB_PASSWORD='postgres' \
  -e DB_PORT=5432 \
  -e PORT=4000 \
  -e HOSTNAME='localhost' \
  -e SECRET_KEY_BASE='SOMETHING_SUPER_SECRET' \
  -p 4000:4000 \
  supabase/realtime
```

## Contributing

- Fork the repo on GitHub
- Clone the project to your own machine
- Commit changes to your own branch
- Push your work back up to your fork
- Submit a Pull request so that we can review your changes and merge

## Releases

To trigger a release you must tag the commit, then push to origin.

```bash
git tag -a 0.x.x -m "Some release details / link to release notes"
git push origin 0.x.x
```

## License

This repo is licensed under Apache 2.0.

## Credits

- [https://github.com/phoenixframework/phoenix](https://github.com/phoenixframework/phoenix) - The server is built with the amazing elixir framework.
- [https://github.com/cainophile/cainophile](https://github.com/cainophile/cainophile) - A lot of this implementation leveraged the work already done on Cainophile.
- [https://github.com/mcampa/phoenix-channels](https://github.com/mcampa/phoenix-channels) - The client library is ported from this library. 
