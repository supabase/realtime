# Supabase Realtime

Listens to changes in a PostgreSQL Database and broadcasts them over websockets.

## Status

> Status: ALPHA

This repo is still under heavy development and likely to change. You're welcome to try it, but expect some breaking changes.

## Docs 

To see the full docs, go to [https://supabase.io/docs/realtime/getting-started](https://supabase.io/docs/realtime/getting-started)

## Getting started

The easiest way to use this is to set up a docker compose:

```sh 
# docker-compose.yml
version: '3'
services:
  realtime:
    image: supabase/realtime
    ports:
      - "4000:4000"
    environment: # Point the server to your own Postgres database
    - POSTGRES_USER=postgres 
    - POSTGRES_PASSWORD=postgres
    - POSTGRES_DB=postgres
    - POSTGRES_HOST=localhost
    - POSTGRES_PORT=5432
```

Then run:

```sh
docker-compose up     # Run in foreground on port 4000
```

## Contributing

We welcome any issues, pull requests, and feedback. See [https://supabase.io/docs/-/contributing](https://supabase.io/docs/-/contributing) for more details.

## License

This repo is liscenced under Apache 2.0.

## Credits

- [https://github.com/cainophile/cainophile](https://github.com/cainophile/cainophile) - A lot of this implementation leveraged the work already done on Canophile.
