# Write policy probe cost

What the `:persistence` write policy probe costs on top of the `:broadcast` probe, and what
batching the two into one call recovers.

## Run it

It probes the dev tenant against this example's policies, so do `setup` first. From the repo root:

```bash
mise run db-start
```

From here:

```bash
mise run setup
```

From the repo root:

```bash
mix run bench/authorization_probe.exs
```

## Results

| Shape | ips | median | 99th | average | deviation |
| -- | -- | -- | -- | -- | -- |
| `:broadcast` only | 1440 | 0.658 ms | 1.359 ms | 0.695 ms | ±31% |
| Both in one call | 1050 | 0.911 ms | 1.733 ms | 0.948 ms | ±27% |
| `:broadcast` then `:persistence`, two calls | 700 | 1.372 ms | 2.562 ms | 1.420 ms | ±22% |
