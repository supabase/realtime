# Agent instructions

Entry point for AI/LLM agents working in or with this repository.

## Guidelines

- [README.md](./README.md) - index documentation.
- [CONTRIBUTING.md](./CONTRIBUTING.md) - how to get started and work on issues and pull requests.
- [DEVELOPERS.md](./DEVELOPERS.md) - technical details of the project.
- [ARCHITECTURE.md](./ARCHITECTURE.md) - overview and glossary.

Other documentation files are listed in README.md

## Migrations

- `priv/repo/migrations` - realtime migrations
- `lib/realtime/tenants/repo/migrations` - tenant migrations

Regenerate tenant schema whenever tenant migrations changes, see `mise.toml`.

## Security

Follow the repository [security policy](https://github.com/supabase/realtime/security/policy).

- Do not open Pull Requests to fix security issues, doing so creates unnecessary risks for all users.
