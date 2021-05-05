# Realtime Server Instructions

## Run locally via mix

```sh
PORT=4000            \
DB_USER=postgres     \
DB_HOST=localhost    \
DB_PASSWORD=postgres \
DB_NAME=postgres     \
DB_PORT=5432         \
SLOT_NAME=TEST_SLOT  \
MIX_ENV=dev          \
mix phx.server
```


## Run locally via releases

1. Create the release:

```sh
PORT=4000            \
DB_USER=postgres     \
DB_HOST=localhost    \
DB_PASSWORD=postgres \
DB_NAME=postgres     \
DB_PORT=5432         \
MIX_ENV=prod         \
mix release
```

2. Start the release:

```sh
PORT=4000 \
DB_USER=postgres \
DB_HOST=localhost \
DB_PASSWORD=postgres \
DB_NAME=postgres \
DB_PORT=5432 \
JWT_SECRET=SOMETHING_SECRET \
SECURE_CHANNELS=false
_build/prod/rel/realtime/bin/realtime start
```


Helpful resources

- [Deploy a Phoenix app with Docker stack](https://dev.to/ilsanto/deploy-a-phoenix-app-with-docker-stack-1j9c)