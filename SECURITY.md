# Security Policy

Thank you for helping keep Supabase Realtime and its users safe.

## Reporting a vulnerability

Please report suspected vulnerabilities through our HackerOne program:
<https://hackerone.com/supabase>. Please do not open public GitHub issues or
pull requests for security problems.

This repository contains the Supabase Realtime server, the service behind
Supabase Realtime: WebSocket connections, Broadcast, Presence, Postgres Changes,
channel authorization, and the tenant management API that configures it. It
runs on the hosted Supabase platform and is also run by people who self-host
it. We accept reports for both, and we triage them differently (see "Hosted vs.
self-hosted" below). For more information see the ARCHITECTURE.md file.

## What we consider a vulnerability

In general, we want to hear about anything that lets an attacker break the
security guarantees Realtime makes to a project and its users: receiving,
sending or tracking messages on a channel they are not allowed to use, reading
database changes their RLS policies should hide, obtaining another user's
credentials, or crossing a boundary between tenants. The attacker should not
need the service-role key, the tenant management API secret or other
privileged credentials, and the problem should be present on the hosted
platform or in a default or documented configuration.

Examples of what this includes (these are illustrations, not a complete list):

- **Channel authorization bypass.** Joining, broadcasting to, or publishing
  presence on a private channel when the RLS policies on `realtime.messages`
  should have denied it, on a project with public access disabled.
- **Postgres Changes that ignore RLS.** Receiving `INSERT` or `UPDATE` events
  for rows the subscriber's role cannot select.
- **Token verification flaws.** A connection or channel join accepted with a
  token that is expired, not signed by the tenant's key, or issued for another
  project.
- **Cross-tenant access.** One tenant's messages, presence state, database
  changes or configuration becoming reachable from another tenant.
- **Credentials exposed to someone who should not see them.** User access
  tokens or other secrets written by the service to logs, error messages or
  responses that other people can read, including logs shown in the dashboard
  or sent to third parties.

## What we do not consider a vulnerability

Reports that rely on the behavior below will normally be closed as
informative or not applicable.

**By design**

- **The publishable (anon) key in the WebSocket URL.** This key is public by
  design. It identifies the project and is not authorization. Browsers cannot
  set headers on a WebSocket connection, so the key goes in the URL. Seeing it,
  or decoding its claims, in client code, network traffic or a demo site is not
  a vulnerability.
- **Access tokens stay valid until they expire.** Realtime verifies stateless
  JWTs. A token that keeps working after the user signs out, until its `exp`,
  is expected. A report needs to show a token accepted *after* its expiry.
- **Channels that are not private.** Channel access is controlled by RLS
  policies only for private channels, with public access disabled. Joining a
  channel that was not made private is not a bypass.
- **Customer-owned policies.** Whether your RLS policies on `realtime.messages`
  and on your tables are correct is your responsibility. A bypass must be shown
  with correct policies.

**Prerequisites that make the attack pointless**

- The attacker needs a valid access token of the victim. Possessing the token
  already grants what you describe.
- The attacker needs the service-role key, the tenant management API secret,
  or admin access to the Realtime dashboard.
- The attacker needs to change the tenant's own configuration first.

**Impact limited to yourself**

- An error or failed connection caused by a tenant's own misconfiguration that
  only affects that tenant's clients. This is a functional bug, not a
  vulnerability.

**Reports that are not evidence of a flaw**

- **Non-sensitive identifiers in logs.** The JWT `sub` claim is a user UUID,
  not personal data. Logging it is not an information leak.
- **Credentials in test, benchmark and example files** that are placeholders
  for a local setup and not valid for any real deployment. Show that a
  credential is live and grants access.
- **Claims with no evidence.** Log output or behavior described but not
  reproduced against a running Realtime server.

## Out of scope for every Supabase asset

These are excluded program-wide (see also
<https://supabase.com/.well-known/security.txt>). They are repeated here so
you do not need to leave this repository to find them.

- Clickjacking on pages with no sensitive actions.
- Unauthenticated, logout and login CSRF.
- Attacks requiring MITM or physical access to a user's device.
- Attacks requiring social engineering.
- Any activity that could lead to the disruption of our service (DoS).
  This means volumetric attacks, load testing and flooding. A vulnerability in
  our code that lets an unprivileged attacker crash a service or exhaust
  resources for other users or tenants is in scope. Denial of service that only
  affects the attacker's own project, or that needs admin or owner privileges,
  is not.
- Content spoofing and text injection issues without showing an attack vector,
  or without being able to modify HTML/CSS.
- Email spoofing.
- Missing DNSSEC, CAA or CSP headers.
- Lack of Secure or HttpOnly flags on non-sensitive cookies.
- Dead links.
- User enumeration.

## Known and documented behavior

These are described in our public documentation. Please check them before
reporting.

- **Private channels need public access disabled.** To enforce private
  channels, the "Allow public access" setting must be disabled. See the Realtime
  Authorization documentation here: 
  https://supabase.com/docs/guides/realtime/authorization.
- **Channel access is cached for the connection.** Policies are checked when a
  client connects and joins a channel, and the result is cached for the
  connection. It is refreshed when the client joins a channel or sends a new
  JWT. A client whose access was revoked keeps receiving messages until its JWT
  expires or a new one is sent.
- **RLS is not applied to `DELETE` events in Postgres Changes.** Postgres
  cannot check a user's access to a row that has been deleted. By default only
  the new record is sent, and `old` records for updates and deletes need the
  table's replica identity set to `full`.
- **The service-role key bypasses RLS.** Do not use it in clients.

## Hosted vs. self-hosted

The example Docker Compose setup ships getting-started values for local use,
such as the dashboard login and the tenant management API secret. Operators
must replace them before any real deployment, so findings that depend on those
defaults being left unchanged are not accepted. A self-hosted Realtime server
also connects to whatever database hosts its operator configures, including
internal networks. Limiting where it can connect is a host and network
hardening task, not a Realtime vulnerability.

We accept self-hosted findings when the shipped code or the documented setup
leads to the problem, and we treat them as lower severity when the operator has
to misconfigure the deployment first, such as with unchanged example secrets or
the management API or dashboard published to the internet. Label your report as
described in the next section.

## How to write a report that gets triaged quickly

- **Say what you tested, at the top of the report and in the title.** Use one of
  these labels, for example `[Production] ...` in the title and a "Target" line
  at the start of the description:
  - **Production**: the hosted Supabase platform, against a project you own.
    Include the project ref. Never test another customer's project.
  - **Self-hosted, default configuration**: the code in this repository run
    exactly as shipped or as our self-hosting guide describes, with no changed
    settings other than the secrets the guide tells you to set. Include the
    version or commit and how you started it.
  - **Self-hosted, custom configuration**: you changed settings, added a proxy,
    or modified code. List every setting you changed and why. We triage these
    lower unless the setting is one we recommend or document.

  Reports that do not say which of the three they are about are slower to
  triage, and are often closed with a request to retest. A finding that works
  only on a custom configuration is not a finding against production.

- **Test a real deployment.** Code reading alone is rarely enough. Static
  analysis findings need a working proof of concept against one of the targets
  above.
- **Give a short, runnable PoC.** A client script or exact WebSocket frames,
  and the output showing the impact, for example the message or database change
  the attacker received. Screenshots of real log output beat a description of
  what a log line would contain.
- **State the attacker's starting position.** What do they hold (the
  publishable key only, their own user JWT, a victim's token, the service-role
  key)? Reports that quietly assume the victim's token or privileged keys are
  our most common reason to close.
- **Name the boundary you crossed.** Which channel, table, user or tenant could
  not be reached before? Include the channel settings (public or private) and
  the RLS policies involved. If nothing was crossed, it is probably a hardening
  suggestion.
- **Check the docs and this file first.** If the behavior is documented,
  explain why the documented design still fails.
- **Include versions.** The Realtime version or commit, the client library and
  version, and the relevant tenant and environment settings.
- **One issue per report.** Link variants of the same root cause instead of
  filing each variant separately.
- **Do not send unreviewed AI output.** Reports that were not reproduced by a
  human and that ignore the documentation are closed. AI-assisted analysis is
  fine when you have verified the result.
- **Respond to follow-up questions.** Reports that go quiet after we ask for a
  reproduction are closed.

## Severity

We rate severity by realistic impact on a default deployment. Issues that need
an unusual configuration, an existing privilege, or a strong prerequisite are
rated lower even when they are valid, and we may fix them as defense in depth.

## Testing and disclosure

These are our program-wide rules. They also apply to AI agents and automated
tools acting on your behalf.

**Testing**

- Do not run automated scanners against other customers' projects. Scanners can
  run up costs for our users, can disrupt services, and our own security
  systems cannot tell hostile reconnaissance from research. If you want to run
  an automated scanner, notify security@supabase.com first and run it only on
  your own Supabase project.
- Do not attack projects that belong to other customers.
- Do not take advantage of a vulnerability you find, for example by downloading
  more data than necessary to demonstrate it, or by deleting or modifying other
  people's data.

**Disclosure**

- Do not reveal the problem to others until we have researched and fixed it and
  informed affected customers.
- If you want to share your research publicly (a conference, a blog or any
  other public forum), send us a draft for review and approval at least 30 days
  before the publication date. Do not include data about Supabase customer
  projects, customers' data, or information about Supabase employees,
  contractors or partners.

**What we promise**

- We will respond to your report within 5 business days with our evaluation and
  an expected resolution date.
- If you have followed these instructions, we will not take legal action against
  you in regard to the report.
- We will handle your report with strict confidentiality and will not pass on
  your personal details to third parties without your permission.
- We will keep you informed of our progress.
- In public information about the problem, we will name you as the discoverer
  unless you prefer otherwise.
