ARG ELIXIR_VERSION=1.18
ARG OTP_VERSION=27.3
ARG DEBIAN_VERSION=bookworm-20250929-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"
ARG ZIG_VERSION=0.15.2

FROM ${BUILDER_IMAGE} AS builder

ARG ZIG_VERSION
ARG BURRITO_TARGET=""

ENV MIX_ENV="prod"
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/cargo/bin:/usr/local/zig:${PATH}"

RUN apt-get update -y && apt-get install -y \
    build-essential git curl xz-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN set -uex; \
    apt-get update; \
    apt-get install -y ca-certificates curl gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    NODE_MAJOR=24; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list; \
    apt-get -qy update; \
    apt-get -qy install nodejs;

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable

RUN if [ -n "${BURRITO_TARGET}" ]; then \
      ARCH=$(uname -m) && \
      curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /usr/local/ && \
      mv /usr/local/zig-${ARCH}-linux-${ZIG_VERSION} /usr/local/zig && \
      rustup target add x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu && \
      cargo install cargo-zigbuild; \
    fi

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY beacon beacon
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY native native
COPY assets assets

RUN cd assets && npm install && cd .. && mix assets.deploy

RUN mix compile

COPY config/runtime.exs config/
COPY rel rel

RUN mkdir -p /app/release && \
    if [ -n "${BURRITO_TARGET}" ]; then \
      BURRITO_TARGET=${BURRITO_TARGET} mix release && \
      cp burrito_out/realtime_${BURRITO_TARGET} /app/release/realtime; \
    else \
      mix release && \
      cp -r _build/prod/rel/realtime/. /app/release/; \
    fi

FROM ${RUNNER_IMAGE}
ARG SLOT_NAME_SUFFIX

ENV SLOT_NAME_SUFFIX="${SLOT_NAME_SUFFIX}" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LC_ALL="en_US.UTF-8" \
    MIX_ENV="prod" \
    ECTO_IPV6="true" \
    ERL_AFLAGS="-proto_dist inet6_tcp" \
    BURRITO_CACHE_DIR=/tmp/burrito_cache

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales iptables sudo tini curl awscli jq && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR "/app"

RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/release ./
COPY run.sh run.sh
RUN ls -la /app

ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/run.sh"]
CMD ["/app/bin/server"]
