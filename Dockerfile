FROM elixir:1.9.4

ENV DB_HOST=localhost \
    DB_NAME=postgres \
    DB_USER=postgres \
    DB_PASSWORD=postgres \
    DB_PORT=5432 \
    MIX_ENV=prod \
    PORT=4000 \
    SECRET_KEY_BASE=123

RUN apt-get update

# Install the realtime server
WORKDIR /app
COPY ./server .
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix deps.compile

EXPOSE 4000

CMD ["mix", "phx.server"]

# docker build . -t realtime