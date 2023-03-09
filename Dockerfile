# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian instead of
# Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20220801-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.14.0-erlang-25.0.4-debian-bullseye-20220801-slim
#
ARG ELIXIR_VERSION=1.14.3
ARG OTP_VERSION=25.3
ARG DEBIAN_VERSION=bullseye-20230227-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM alpine:latest as tailscale
ARG TAILSCALE_VERSION=1.32.2
WORKDIR /app
ENV TSFILE=tailscale_${TAILSCALE_VERSION}_amd64.tgz
RUN wget https://pkgs.tailscale.com/stable/${TSFILE} && tar xzf ${TSFILE} --strip-components=1
COPY tailscale/wrapper.sh ./

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y \
  && apt-get install curl -y \
  && apt-get install -y build-essential git \
  && apt-get clean \
  && rm -f /var/lib/apt/lists/*_* \
  && curl -sL https://deb.nodesource.com/setup_18.x | bash - \
  && apt-get install -y nodejs

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
  mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

COPY lib lib

COPY assets assets

# compile assets with esbuild and npm
RUN cd assets \
  && npm install \
  && cd .. \
  && mix assets.deploy

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales iptables sudo tini \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# put commit sha
# deploy with `flyctl deploy --build-arg SLOT_NAME_SUFFIX=$(git rev-parse --short HEAD)`
ARG SLOT_NAME_SUFFIX
ENV SLOT_NAME_SUFFIX="${SLOT_NAME_SUFFIX}"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/realtime ./

RUN mkdir /tailscale
COPY --from=tailscale /app/wrapper.sh /tailscale/wrapper.sh
COPY --from=tailscale /app/tailscaled /tailscale/tailscaled
COPY --from=tailscale /app/tailscale /tailscale/tailscale
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale

ENV RLIMIT_NOFILE 100000
COPY limits.sh /app/limits.sh
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/limits.sh"]

CMD ["/tailscale/wrapper.sh"]
# Appended by flyctl
ENV ECTO_IPV6 true
ENV ERL_AFLAGS "-proto_dist inet6_tcp"
