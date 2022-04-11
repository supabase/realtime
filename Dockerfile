###
### Fist Stage - Building the Release
###
FROM hexpm/elixir:1.13.1-erlang-24.0.1-alpine-3.13.3 AS build

# install build dependencies
RUN apk add --no-cache build-base npm git

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV as prod
ENV MIX_ENV=prod
ENV SECRET_KEY_BASE=nokey

# Copy over the mix.exs and mix.lock files to load the dependencies. If those
# files don't change, then we don't keep re-fetching and rebuilding the deps.
COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod && \
    mix deps.compile

# install npm dependencies
# COPY assets/package.json assets/package-lock.json ./assets/
# RUN npm --prefix ./assets ci --progress=false --no-audit --loglevel=error

COPY priv priv
# COPY assets assets

# NOTE: If using TailwindCSS, it uses a special "purge" step and that requires
# the code in `lib` to see what is being used. Uncomment that here before
# running the npm deploy script if that's the case.
COPY lib lib

# build assets
# RUN npm run --prefix ./assets deploy
RUN mix phx.digest

# copy source here if not using TailwindCSS
# COPY lib lib

# compile and build release
COPY rel rel
RUN mix do compile, release

###
### Second Stage - Setup the Runtime Environment
###

# prepare release docker image
FROM alpine:3.13.3 AS app
RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

RUN chown nobody:nobody /app

# USER root

COPY --from=build --chown=nobody:nobody /app/_build/prod/rel/realtime ./
# COPY --from=build /app/_build/prod/rel/realtime ./

ENV HOME=/app
ENV MIX_ENV=prod

# COPY limits.sh ./limits.sh
# RUN chmod +x /app/limits.sh
# ENTRYPOINT ["/app/limits.sh"]
CMD ["bin/realtime", "start"]
