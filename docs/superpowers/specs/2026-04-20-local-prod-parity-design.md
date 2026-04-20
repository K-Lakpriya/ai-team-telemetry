# Local/Prod Parity for `aimonitor` — Design

**Date:** 2026-04-20
**Status:** Approved design; pending implementation plan.

## Context

The stack originally ran only on a VPS: Caddy terminates TLS for Grafana on `:443` and for OTLP gRPC on `:4317`, backed by an OTEL Collector, Prometheus, Loki, and Grafana. Recent commits introduced laptop-friendly changes (Caddy-bypass for OTLP, Grafana on host port `3001`, removed `:4317` Caddy block) that diverged from the VPS shape. This design restores the divergence and makes the *same compose + configs* drive both environments — the only delta is `.env` values and the presence or absence of a local override file.

The four axes that differ between local and prod, and the resolution for each:

| Axis | Prod | Local (this design) |
|---|---|---|
| OTLP transport | Caddy-terminated TLS on `:4317` | **Same** — Caddy with `tls internal` on `:4317` |
| Caddy TLS | Let's Encrypt for `VPS_DOMAIN` | `tls internal` (Caddy-signed) |
| Grafana root URL | `https://monitor.example.com` | `https://aimonitor.local` |
| Host port exposure | `:80 :443 :4317` public + Grafana on loopback `:3000` | Same + extra loopback debug ports (Grafana stays on `:3000`) |

## Goals

- Zero code changes between environments. Only `.env` and the optional presence of `docker-compose.local.yml` distinguish them.
- Prod is the default. On the VPS, `docker compose up -d` with no flags does the right thing.
- Local stack is **structurally identical** to prod: Caddy fronts everything, OTLP flows over TLS on `:4317`, Grafana is reached at `https://aimonitor.local` — no shortcuts that would hide prod-only bugs.
- Safety: no chance of deploying a local-flavored Caddyfile to the VPS (no Let's Encrypt misconfiguration, no self-signed certs).

## Non-goals

- Not supporting a third environment (staging, CI). If those are wanted later, the same override mechanism extends cleanly.
- Not changing retention, passwords, or anything else between environments — parity is explicit.
- Not running smoke tests on the VPS. Smoke is a local-only tool.

## Architecture

### Compose layering

- **`docker-compose.yml`** (prod baseline, always loaded)
  - Caddy publishes `:80 :443 :4317`, mounts `./caddy/Caddyfile`.
  - `otel-collector` has **no** host ports — reachable only via Caddy or inside the `monitor` network.
  - `prometheus`, `loki` have **no** host ports — reachable only inside the `monitor` network.
  - `grafana` binds `127.0.0.1:3000:3000` (loopback only) — for SSH-tunneled admin access on the VPS. Public access is via Caddy on `:443`.
- **`docker-compose.local.yml`** (explicit override, loaded only via `just up`)
  - Swaps Caddy volume to `./caddy/Caddyfile.local`.
  - Does **not** touch `grafana.ports` — Grafana uses the base binding `127.0.0.1:3000:3000` locally too. The user is responsible for keeping host port `3000` free on the laptop (kill any other local service on `:3000` before `just up`).
  - Adds loopback host bindings for direct debugging (none of these exist in base):
    - `prometheus`: `127.0.0.1:9090:9090`
    - `loki`: `127.0.0.1:3100:3100`
    - `otel-collector`: `127.0.0.1:8888:8888`, `127.0.0.1:13133:13133`
  - Does **not** add a loopback binding for `otel-collector:4317`. Local OTLP traffic goes through Caddy on `aimonitor.local:4317` with TLS — exactly like prod.

Because the override only *adds* port entries (never remaps Grafana), Compose's default list-concatenation behavior is fine and no `!override` YAML tag is needed.

### Caddy

Two Caddyfiles, identical structure, different TLS directive.

**`caddy/Caddyfile`** (prod, restored to pre-local-dev state):

```caddy
{
    email {$CADDY_EMAIL}
}

{$VPS_DOMAIN} {
    reverse_proxy grafana:3000
}

{$VPS_DOMAIN}:4317 {
    reverse_proxy h2c://otel-collector:4317
}
```

**`caddy/Caddyfile.local`** (new, for local dev):

```caddy
{
    email {$CADDY_EMAIL}
}

{$VPS_DOMAIN} {
    tls internal
    reverse_proxy grafana:3000
}

{$VPS_DOMAIN}:4317 {
    tls internal
    reverse_proxy h2c://otel-collector:4317
}
```

With `tls internal`, Caddy maintains a local CA at `/data/caddy/pki/authorities/local/root.crt` inside the container (persisted in the `caddy_data` volume). That root must be trusted on the host for TLS to validate when tools hit `aimonitor.local`.

### `.env`

Local `.env`:
```
VPS_DOMAIN=aimonitor.local
CADDY_EMAIL=dev@localhost          # unused by tls internal, but the global { email } block still interpolates
OTEL_BEARER_TOKEN=<openssl rand -hex 32>
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<anything>
```

Prod `.env` (on VPS, unchanged from original):
```
VPS_DOMAIN=monitor.yourdomain.com
CADDY_EMAIL=admin@yourdomain.com
OTEL_BEARER_TOKEN=<openssl rand -hex 32>
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<strong>
```

Grafana's `GF_SERVER_ROOT_URL=https://${VPS_DOMAIN}` resolves correctly in both environments with no override needed.

### `/etc/hosts`

Local dev requires a one-time host entry:
```
127.0.0.1   aimonitor.local
```

Without it, `aimonitor.local` won't resolve (or worse, will hit mDNS/Bonjour — see Risks).

## Justfile changes

Additions/edits (current recipes that stay: `setup`, `token`, `down`, `reset`, `restart`, `pull`, `reload`, `ps`, `logs`, `metrics`, `prom`, `validate`):

| Recipe | Behavior |
|---|---|
| `just up` | Checks `$VPS_DOMAIN` ends in `.local` or `.test`; aborts with an error otherwise (prevents accidentally starting the local stack against the prod domain, which would try `tls internal` on a public name). Then: `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d`. |
| `just up-prod` | `docker compose up -d` (prod default, no override file loaded) |
| `just down` | `docker compose -f docker-compose.yml -f docker-compose.local.yml down` (works even when override hasn't been loaded) |
| `just reload` | `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate` |
| `just open` | `open https://aimonitor.local` (replaces `http://localhost:3001`); Grafana is also directly reachable at `http://localhost:3000` via the loopback binding for quick UI work that doesn't need TLS |
| `just hosts-check` | Greps `/etc/hosts` for `aimonitor.local` entry pointing at `127.0.0.1`; prints copy-paste instructions if missing. Called automatically from `just setup` as a non-fatal warning. |
| `just trust-cert` | One-shot: ensures Caddy is up, `docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-local-root.crt`, runs `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./caddy-local-root.crt` (sudo prompt), then prints the `NODE_EXTRA_CA_CERTS` env var snippet for the user to add to their shell profile. The extracted CA path (`./caddy-local-root.crt`) is stable so the env var doesn't break on re-runs. |
| `just ping` | Replaced: `curl -sf -o /dev/null -w "%{http_code}" --resolve aimonitor.local:4317:127.0.0.1 https://aimonitor.local:4317 -H "Authorization: Bearer $OTEL_BEARER_TOKEN"` — verifies Caddy is routing and TLS handshake succeeds. (The `--resolve` flag makes the recipe portable even if `/etc/hosts` is misconfigured.) |
| `just smoke` | Rewritten, see below |
| `just clean-data` | `docker compose stop prometheus loki && docker volume rm aimonitor_prometheus_data aimonitor_loki_data && docker compose start prometheus loki` — wipes metric/log data without touching Grafana dashboards/users or Caddy's trusted CA |

Added file `./caddy-local-root.crt` is gitignored.

## Smoke test changes

`scripts/smoke-test.sh` is rewritten to hit the **public Caddy endpoints** with the expectation that the local CA has been trusted:

- `GET https://aimonitor.local/api/health` → `ok`
- `GET https://aimonitor.local/api/datasources/name/Prometheus` (authed) → `prometheus`
- `GET https://aimonitor.local/api/datasources/name/Loki` (authed) → `loki`
- `GET https://aimonitor.local/api/search?tag=claude-code` (authed) → dashboards.length == 4
- New: TLS trust check — `curl -sf https://aimonitor.local/api/health` without `-k` must succeed. If it fails, the script prints "run `just trust-cert` first" and exits.
- `TLS handshake on aimonitor.local:4317` — `openssl s_client -connect aimonitor.local:4317 -servername aimonitor.local` succeeds (collector reachability via Caddy).
- Loopback debug endpoints (local-only, still useful for smoke): `http://localhost:3000/api/health` (Grafana direct, pre-TLS), `http://localhost:9090/-/ready`, `http://localhost:3100/ready`, `http://localhost:13133/`, `http://localhost:8888/metrics`.
- Keeps: Prometheus-is-scraping-collector check, accessed via `http://localhost:9090` (loopback, present in local override).

Kept from earlier local-dev changes: `((PASS++)) || true` fix (strict improvement unrelated to environment split).

## Revert plan (changes that conflict with this design)

These items from the earlier local-dev commits need to be reverted:

1. **`caddy/Caddyfile`** — restore the `{$VPS_DOMAIN}:4317 { reverse_proxy h2c://otel-collector:4317 }` block.
2. **`docker-compose.yml`** — remove `"127.0.0.1:4317:4317"`, `"127.0.0.1:8888:8888"`, and `"127.0.0.1:13133:13133"` from `otel-collector.ports` (8888/13133 move to the local override; 4317 goes away entirely — OTLP comes through Caddy); remove `"127.0.0.1:9090:9090"` from Prometheus; remove `"127.0.0.1:3100:3100"` from Loki; change Grafana binding from `"127.0.0.1:3001:3000"` back to `"127.0.0.1:3000:3000"`.
3. Caddy's `ports` list must include `"4317:4317"` again.

Kept from earlier local-dev changes (strict improvements, environment-agnostic):
- Removal of `version: '3.8'` top-level key.
- `((PASS++)) || true` fix in smoke test.

## Operational workflow

**Laptop (first-time setup):**
1. `just setup` → creates `.env` with `VPS_DOMAIN=aimonitor.local`
2. Add `127.0.0.1 aimonitor.local` to `/etc/hosts`; `just hosts-check` verifies.
3. `just up` → stack starts with local override.
4. `just trust-cert` → installs Caddy's local root CA into macOS keychain; prints the absolute path of `./caddy-local-root.crt` and the `NODE_EXTRA_CA_CERTS` snippet.
5. **Verify Node trust.** Run:
   ```bash
   node -e "require('https').get('https://aimonitor.local/api/health', r => console.log(r.statusCode)).on('error', e => console.error('FAIL:', e.code))"
   ```
   If it prints `200`, Node already trusts the cert (e.g., via a future Node version that reads the system keychain) — skip step 6.
   If it prints `FAIL: UNABLE_TO_VERIFY_LEAF_SIGNATURE` (or similar), proceed to step 6.
6. Add `export NODE_EXTRA_CA_CERTS="$HOME/Developer/personal/aimonitor/caddy-local-root.crt"` to `~/.zshrc` (adjust path as needed); open a new shell. Re-run step 5 to confirm `200`.
7. `just smoke` → validates end-to-end.
8. Configure Claude Code shell env with `OTEL_EXPORTER_OTLP_ENDPOINT=https://aimonitor.local:4317`.

**Laptop (daily):** `just up`, `just logs <svc>`, `just down`.

**VPS (deploy):**
1. `git pull` — pulls this repo with `docker-compose.yml`, `caddy/Caddyfile`, `caddy/Caddyfile.local`, `docker-compose.local.yml`.
2. `.env` already exists on VPS with prod values.
3. `docker compose up -d` (or `just up-prod`) — base compose only, Let's Encrypt Caddyfile, no loopback debug ports. `docker-compose.local.yml` and `caddy/Caddyfile.local` are **present on disk but unreferenced** by the prod command.

The `docker-compose.local.yml` file is committed to git; it's inert on the VPS because no one asks Compose to load it.

## Risks and mitigations

1. **`.local` TLD on macOS.** `.local` is reserved for mDNS (RFC 6762). macOS `/etc/hosts` lookups for `.local` generally work, but some Java-based tools and odd resolver paths may bypass `/etc/hosts` and query mDNS. **Mitigation:** if `aimonitor.local` resolution misbehaves, swap to `aimonitor.test` (RFC 2606 reserved, no mDNS handling). All recipes parameterize `VPS_DOMAIN`, so the switch is a `.env` edit only.

2. **Node.js ignores the system keychain.** Claude Code is Node-based. `security add-trusted-cert` covers macOS apps (browsers, curl, Python, Go) but Node uses its bundled `ca-certificates`. **Mitigation:** `just trust-cert` copies the CA to a stable path (`./caddy-local-root.crt`) and prints the `NODE_EXTRA_CA_CERTS` snippet the user must add to their shell profile. Smoke test flags missing Node trust indirectly via the TLS-handshake check (if the `just ping` recipe fails for Claude Code specifically, the user knows Node trust is missing even if curl works).

3. **Local port-3000 collisions.** Grafana binds the laptop's `127.0.0.1:3000:3000` locally. If another dev tool (Create React App, Rails, Next.js dev server) is already on `:3000`, `just up` fails. By design, the user manages this manually — `lsof -iTCP:3000 -sTCP:LISTEN` finds the offender, stop it before `just up`. We don't want to paper over this with different ports in local, because port parity with prod is a small but real benefit (any hardcoded `localhost:3000` path in notes/runbooks works in both places).

4. **Accidentally using local recipes on VPS.** If someone on the VPS runs `just up` thinking it's the prod recipe, they'd try to start with `tls internal` on a public domain. **Mitigation:** `just up` includes a hard guard — reads `$VPS_DOMAIN` from `.env` and aborts unless it ends in `.local` or `.test`. Error message: "just up is for local dev only (VPS_DOMAIN must end in .local or .test). Use just up-prod on the VPS." `just up-prod` has the mirror guard: aborts if `$VPS_DOMAIN` *does* end in `.local`/`.test`.

5. **Caddy internal CA rotation.** Caddy auto-rotates its internal CA. If the user has pinned the extracted cert via `NODE_EXTRA_CA_CERTS` and Caddy issues a new root, Node will start failing verification. **Mitigation:** `just trust-cert` is idempotent — rerun to refresh. Smoke test's TLS check catches stale trust.

6. **Caddy state in `caddy_data` volume.** `just reset` / `docker compose down -v` wipes the CA. User must rerun `just trust-cert` after a reset. `just clean-data` is provided specifically to avoid this: it wipes *data* (prom, loki) but leaves Caddy + Grafana volumes intact.

## Files changed

Created:
- `docker-compose.local.yml`
- `caddy/Caddyfile.local`
- `docs/superpowers/specs/2026-04-20-local-prod-parity-design.md` (this file)

Modified:
- `docker-compose.yml` (revert local-dev port changes; restore prod shape)
- `caddy/Caddyfile` (restore `:4317` block)
- `Justfile` (new recipes: `up-prod`, `hosts-check`, `trust-cert`, `clean-data`; edits to `up`, `down`, `reload`, `open`, `ping`, `smoke`)
- `scripts/smoke-test.sh` (rewrite for `https://aimonitor.local` + TLS-trust check)
- `.env.example` (keep as prod template; add a comment showing local alt values)
- `AGENTS.md` (refresh workflow section to reference `aimonitor.local`, `trust-cert`, and local vs. prod command split)
- `.gitignore` (add `/caddy-local-root.crt`)
