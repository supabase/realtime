# Supabase Realtime

Listens to changes in a PostgreSQL Database and broadcasts them over websockets. 



## Dev

```sh
docker-compose up   # start the database
mix phx.server      # start the elixir app
```

## Release


```sh
# Build the image
docker build -t registry.gitlab.com/nimbusforwork/nimbus-monorepo/nimbus-kong ./

# Tag the image
docker tag \
registry.gitlab.com/nimbusforwork/nimbus-monorepo/nimbus-kong:latest \
registry.gitlab.com/nimbusforwork/nimbus-monorepo/nimbus-kong:staging


# Push the image
docker push registry.gitlab.com/nimbusforwork/nimbus-monorepo/nimbus-kong:latest
```