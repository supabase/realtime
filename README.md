# Supabase Realtime

> **⚠ WARNING: v0.10.0 Breaking Change **  
> Channels connections are secured by default in production. See [Channels Authorization](#channels-authorization) for more info.

Listens to changes in a PostgreSQL Database and broadcasts them over websockets.

<p align="center"><kbd><img src="./examples/next-js/demo.gif" alt="Demo"/></kbd></p>

**Contents**

- [Hiring](#hiring)
- [Status](#status)
- [Example](#example)
- [Introduction](#introduction)
    - [What is this?](#what-is-this)
    - [Cool, but why not just use Postgres' `NOTIFY`?](#cool-but-why-not-just-use-postgres-notify)
    - [What are the benefits?](#what-are-the-benefits)
- [Quick start](#quick-start)
- [Client libraries](#client-libraries)
- [Server](#server)
  - [Database set up](#database-set-up)
  - [Server set up](#server-set-up)
  - [Channels Authorization](#channels-authorization)
- [Contributing](#contributing)
- [Releasing](#releasing)
- [License](#license)
- [Credits](#credits)
- [Sponsors](#sponsors)

## Hiring

Supabase is hiring an Elixir expert to work full-time on this repo. If you have the experience, get in touch.

## Status

- [x] Alpha: Under heavy development
- [x] Public Alpha: Ready for use. But go easy on us, there may be a few kinks.
- [x] Public Beta: Stable enough for most non-enterprise use-cases
- [ ] Public: Production-ready

This repo is still under heavy development and the documentation is evolving. You're welcome to try it, but expect some breaking changes. Watch "releases" of this repo to get notified of major updates. And give us a star if you like it!

![Watch this repo](https://gitcdn.xyz/repo/supabase/monorepo/master/web/static/watch-repo.gif "Watch this repo")

## Example

```js
import { Socket } = '@supabase/realtime-js'

var socket = new Socket(process.env.REALTIME_URL)
socket.connect()

// Listen to all changes to user ID 99
var allChanges = this.socket.channel('realtime:public:users:id.eq.99')
  .join()
  .on('*', payload => { console.log('Update received!', payload) })

// Listen to only INSERTS on the 'users' table in the 'public' schema
var allChanges = this.socket.channel('realtime:public:users')
  .join()
  .on('INSERT', payload => { console.log('Update received!', payload) })

// Listen to all updates from the 'public' schema
var allChanges = this.socket.channel('realtime:public')
  .join()
  .on('UPDATE', payload => { console.log('Update received!', payload) })

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
2. NOTIFY has a payload limit of 8000 bytes and will fail for anything larger. The usual solution is to send an ID then fetch the record, but that's heavy on the database
3. This server consumes one connection to the database, then you can connect many clients to this server. Easier on your database, and to scale up you just add realtime servers

#### What are the benefits?

1. The beauty of listening to the replication functionality is that you can make changes to your database from anywhere - your API, directly in the DB, via a console etc - and you will still receive the changes via websockets.
2. Decoupling. For example, if you want to send a new slack message every time someone makes a new purchase you might build that functionality directly into your API. This allows you to decouple your async functionality from your API.
3. This is built with Phoenix, an [extremely scalable Elixir framework](https://www.phoenixframework.org/blog/the-road-to-2-million-websocket-connections)


## Quick start

We have set up some simple examples that show how to use this server:

- [Next.js example](https://github.com/supabase/realtime/tree/master/examples/next-js)
- [NodeJS example](https://github.com/supabase/realtime/tree/master/examples/node-js)


## Client libraries

- Javascript: [@supabase/realtime-js](https://github.com/supabase/realtime-js)
- Python: [@supabase/realtime-py](https://github.com/supabase/realtime-py)
- Dart: [@supabase/realtime-dart](https://github.com/supabase/realtime-dart)
- C#: [@supabase/realtime-csharp](https://github.com/supabase/realtime-csharp) [WIP]


## Server

### Database set up

There are a some requirements for your database

1. It must be Postgres 10+ as it uses logical replication
2. Set up your DB for replication
   1. it must have the `wal_level` set to logical. You can check this by running `SHOW wal_level;`. To set the `wal_level`, you can call `ALTER SYSTEM SET wal_level = logical;`
   2. You must set `max_replication_slots` to at least 1: `ALTER SYSTEM SET max_replication_slots = 5;`
3. Create a `PUBLICATION` for this server to listen to: `CREATE PUBLICATION supabase_realtime FOR ALL TABLES;`
4. [OPTIONAL] If you want to receive the old record (previous values) on UPDATE and DELETE, you can set the `REPLICA IDENTITY` to `FULL` like this: `ALTER TABLE your_table REPLICA IDENTITY FULL;`. This has to be set for each table unfortunately.

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
  -e JWT_SECRET='SOMETHING_SUPER_SECRET' \
  -p 4000:4000 \
  supabase/realtime
```

**OPTIONS**

```sh
DB_HOST                 # {string}           Database host URL
DB_NAME                 # {string}           Postgres database name
DB_USER                 # {string}           Database user
DB_PASSWORD             # {string}           Database password
DB_PORT                 # {number}           Database port
SLOT_NAME               # {string}           A unique name for Postgres to track where this server has "listened until". If the server dies, it can pick up from the last position. This should be lowercase.
PORT                    # {number}           Port which you can connect your client/listeners
SECURE_CHANNELS         # {string}           (options: 'true' or 'false') Enable/Disable channels authorization via JWT verification.
JWT_SECRET              # {string}           HS algorithm octet key (e.g. "95x0oR8jq9unl9pOIx"). Only required if SECURE_CHANNELS is set to true.
JWT_CLAIM_VALIDATORS    # {string}           Expected claim key/value pairs compared to JWT claims via equality checks in order to validate JWT. e.g. '{"iss": "Issuer", "nbf": 1610078130}'. This is optional but encouraged.
SOCKET_TIMEOUT          # {number/string}    Set websocket timeout value to a larger number, in milliseconds, or "infinity" when consistently processing large transactions and/or high volume of transactions. Defaults to 60000 (milliseconds).
```

**EXAMPLE: RUNNING SERVER WITH ALL OPTIONS**

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
  -e JWT_SECRET='SOMETHING_SUPER_SECRET' \
  -p 4000:4000 \
  -e SECURE_CHANNELS='true' \
  -e JWT_SECRET='jwt-secret' \
  -e JWT_CLAIM_VALIDATORS='{"iss": "Issuer", "nbf": 1610078130}' \
  supabase/realtime
```

### Channels Authorization

Channels connections are authorized via JWT verification. Only supports JWTs signed with the following algorithms:
  - HS256
  - HS384
  - HS512

Verify JWT claims by setting JWT_CLAIM_VALIDATORS:

  > e.g. {'iss': 'Issuer', 'nbf': 1610078130}
  >
  > Then JWT's "iss" value must equal "Issuer" and "nbf" value must equal 1610078130.

**NOTE:** JWT expiration is checked automatically. 

**Development**: Channels are not secure by default. Set SECURE_CHANNELS to `true` to test JWT verification locally.

**Production**: Channels are secure by default and you must set JWT_SECRET. Set SECURE_CHANNELS to `false` to proceed without checking authorization.

## Contributing

- Fork the repo on GitHub
- Clone the project to your own machine
- Commit changes to your own branch
- Push your work back up to your fork
- Submit a Pull request so that we can review your changes and merge

## Releasing

- Make a commit to bump the version in `mix.exs`
- Tag the commit

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


## Sponsors

We are building the features of Firebase using enterprise-grade, open source products. We support existing communities wherever possible, and if the products don’t exist we build them and open source them ourselves. 

[![New Sponsor](https://user-images.githubusercontent.com/10214025/90518111-e74bbb00-e198-11ea-8f88-c9e3c1aa4b5b.png)](https://github.com/sponsors/supabase)

