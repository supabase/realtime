<br />
<p align="center">
  <a href="https://supabase.io">
        <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/supabase-logo-wordmark--dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/supabase-logo-wordmark--light.svg">
      <img alt="Supabase Logo" width="300" src="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/logo-preview.jpg">
    </picture>
  </a>

  <h1 align="center">Supabase Realtime</h1>

  <p align="center">
    Send ephemeral messages, track and synchronize shared state, and listen to Postgres changes all over WebSockets.
    <br />
    <a href="https://supabase.com/docs/guides/realtime#examples">Examples</a>
    ·
    <a href="https://github.com/orgs/supabase/discussions/new?category=feature-requests">Request Features</a>
    ·
    <a href="https://github.com/supabase/realtime/issues/new?assignees=&labels=bug&template=1.Bug_report.md">Report Bugs</a>
    <br />
  </p>
</p>

## Status

[![GitHub License](https://img.shields.io/github/license/supabase/realtime)](https://github.com/supabase/realtime/blob/main/LICENSE)
[![Coverage Status](https://coveralls.io/repos/github/supabase/realtime/badge.svg?branch=main)](https://coveralls.io/github/supabase/realtime?branch=main)

| Features         | v1  | v2  | Status |
| ---------------- | --- | --- | ------ |
| Postgres Changes | ✔   | ✔   | GA     |
| Broadcast        |     | ✔   | GA     |
| Presence         |     | ✔   | GA     |

This repository focuses on version 2 but you can still access the previous version's [code](https://github.com/supabase/realtime/tree/v1) and [Docker image](https://hub.docker.com/layers/supabase/realtime/v1.0.0/images/sha256-e2766e0e3b0d03f7e9aa1b238286245697d0892c2f6f192fd2995dca32a4446a). For the latest Docker images go to https://hub.docker.com/r/supabase/realtime.

The codebase is under heavy development and the documentation is constantly evolving. Give it a try and let us know what you think by creating an issue. Watch [releases](https://github.com/supabase/realtime/releases) of this repo to get notified of updates. And give us a star if you like it!

## Overview

### What is this?

This is a server built with Elixir using the [Phoenix Framework](https://www.phoenixframework.org) that enables the following functionality:

- Broadcast: Send ephemeral messages from client to clients with low latency.
- Presence: Track and synchronize shared state between clients.
- Postgres Changes: Listen to Postgres database changes and send them to authorized clients.

For a more detailed overview head over to [Realtime guides](https://supabase.com/docs/guides/realtime).

### Does this server guarantee message delivery?

The server does not guarantee that every message will be delivered to your clients so keep that in mind as you're using Realtime.

## Quick start

You can check out the [Supabase UI Library](https://supabase.com/ui) Realtime components and the [repository](https://github.com/supabase/multiplayer.dev) of the [multiplayer.dev](https://multiplayer.dev) demo app.

## Developers

Start with [DEVELOPERS.md](DEVELOPERS.md) for local setup, `mise` tasks, and example workflows.

Once your environment is up and running, check out the following docs to customize the server and troubleshooting:

- [ENVS.md](ENVS.md) - detailed list of all environment variables
- [ERROR_CODES.md](ERROR_CODES.md) - list of operational codes
- [OBSERVABILITY_METRICS.md](OBSERVABILITY_METRICS.md) - monitoring information

## Postgres compatibility

| `supabase/postgres` version       | Role                      | Status                                                                                                                                                                                                                                      |
| --------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| < 14                              | -                         | Not officially supported.                                                                                                                                                                                                                   |
| 14.x                              | `supabase_admin`          | Requires superuser: `log_min_messages` can only be set by a superuser; supautils doesn't expose per-parameter delegation on this version. On <= 14.5, `realtime.broadcast_changes(...)` called from a trigger via `PERFORM` is unsupported. |
| 15.x < 15.14.1.018                | `supabase_admin`          | Requires superuser: `supautils.policy_grants` on `realtime.subscription` is missing until [supabase/postgres@1b916920](https://github.com/supabase/postgres/commit/1b916920).                                                               |
| 15.x >= 15.14.1.018, 16.x, 17.x   | `supabase_admin`          | Requires superuser to run migrations, no superuser needed for tenant grants. Policies are managed by supautils.                                                                                                                             |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

## Code of Conduct

See [supabase/CODE_OF_CONDUCT.md](https://github.com/supabase/.github/blob/main/CODE_OF_CONDUCT.md)

## License

This repo is licensed under Apache 2.0.

## Credits

- [Phoenix](https://github.com/phoenixframework/phoenix) - `Realtime` server is built with the amazing Elixir framework.
- [Phoenix Channels JavaScript Client](https://github.com/phoenixframework/phoenix/tree/master/assets/js/phoenix) - [@supabase/realtime-js](https://github.com/supabase/realtime-js) client library heavily draws from the Phoenix Channels client library.
