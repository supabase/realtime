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

## Pull requests

The PR title becomes the squash commit that semantic-release reads.

- Title format: `type(scope): summary`, scope optional, summary lowercase with no trailing period.
- Types: `feat` (minor release), `fix` and `perf` (patch release), `build`, `ci`, `docs`, `refactor`, `test`, `revert`, `chore` (no release).
- Do not use `!`; the title check rejects it. A breaking change needs a `BREAKING CHANGE:` footer added to the squash commit message at merge time.

## Security

Follow the repository [security policy](https://github.com/supabase/realtime/security/policy).

- Do not open Pull Requests to fix security issues, disclosing security issues publicly creates unnecessary risks for all users.
