FROM elixir:1.9.0-alpine AS build

## TODO: remove this and pass it in as a build var
ENV SECRET_KEY_BASE=dumb

# install build dependencies
RUN apk add --no-cache build-base nodejs-current npm git python

RUN node --version

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV=prod

# install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
RUN mix do deps.get, deps.compile

# build assets
COPY assets/package.json assets/package-lock.json ./assets/
RUN npm --prefix ./assets ci --progress=false --no-audit --loglevel=error

COPY priv priv
COPY assets assets
RUN npm run --prefix ./assets deploy
RUN mix phx.digest

# compile and build release
COPY lib lib
# uncomment COPY if rel/ exists
# COPY rel rel
RUN mix do compile, release

# prepare release image
FROM alpine:3.9 AS app
RUN apk add --no-cache openssl ncurses-libs

WORKDIR /app

RUN chown nobody /app

USER nobody

COPY --from=build --chown=nobody /app/_build/prod/rel/multiplayer ./

ENV HOME=/app

CMD ["bin/multiplayer", "start"]