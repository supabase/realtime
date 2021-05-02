# Realtime server

## Run locally

```sh
PORT=4000 \
HOSTNAME=localhost \
DB_USER=postgres \
DB_HOST=localhost \
DB_PASSWORD=postgres \
DB_NAME=postgres \
DB_PORT=5432 \
DB_PORT=5432 \
SLOT_NAME=TEST_SLOT \
mix phx.server
```


## Realtime Elixir Instructions

Create the release:

```sh

DB_HOST=localhost
DB_NAME=postgres
DB_USER=postgres
DB_PASSWORD=postgres
DB_PORT=5432
APP_PORT=4000
APP_HOSTNAME=localhost

MIX_ENV=prod mix release
```

Start the release:

```sh
JWT_SECRET=SOMETHING_SECRET \
PORT=4000 \
HOSTNAME=localhost \
DB_USER=postgres \
DB_HOST=localhost \
DB_PASSWORD=postgres \
DB_NAME=postgres \
DB_PORT=5432 \
DB_PORT=5432 \
_build/prod/rel/realtime/bin/realtime start
```


Helpful resources

- [Deploy a Phoenix app with Docker stack](https://dev.to/ilsanto/deploy-a-phoenix-app-with-docker-stack-1j9c)