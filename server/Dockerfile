FROM elixir:1.8-alpine

RUN apk update && apk add inotify-tools postgresql-dev

WORKDIR /app

COPY mix* ./
RUN mix local.hex --force && mix local.rebar --force \
    && mix deps.get && mix deps.compile

COPY . .

EXPOSE 4000

CMD ["mix", "phx.server"]