# Broadcast storage benchmarks: Option 1 (`realtime.channels` table) vs Option 3 (one RLS policy per topic)

Each scenario is self-contained: spins up a disposable Postgres container, seeds what it needs, prints a results table, tears the container down.

## Run one scenario

```sh
./scenario_1.sh   # Time to insert messages
./scenario_2.sh   # Time to insert config
./scenario_3.sh   # Disable one config, at scale
./scenario_4.sh   # Check if a topic has storage enabled
./scenario_5.sh   # List all topics with storage enabled
./scenario_6.sh   # Check since when storage is enabled
./scenario_7.sh   # Storage size per config
./scenario_8.sh   # Does enabling/disabling a config block other topics' inserts?
```

## Run all of them

```sh
./run_all.sh
```

