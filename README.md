# ai-team-telemetry

Open-source telemetry stack for monitoring AI tool usage across development teams. Track per-developer cost, token usage, session activity, and efficiency signals with Prometheus, Loki, and Grafana.

`ai-team-telemetry` is built for CTOs, engineering managers, and dev team leads who want a self-hosted way to understand how AI coding tools are being used across a team without sending telemetry to another SaaS dashboard.

The project is experimental but usable today. Claude Code is the first supported integration. Codex and opencode support are planned next, with more AI agentic tools to follow.

## Why Use It

- **Track cost by developer and team**: see where AI spend is going instead of treating usage as a monthly black box.
- **Understand token usage**: monitor input, output, cache, and total token patterns across sessions.
- **Spot waste and efficiency issues**: identify expensive workflows, repeated activity, and model usage patterns that need attention.
- **Keep telemetry self-hosted**: run the stack on your own laptop, VPS, or internal infrastructure.
- **Use boring, proven observability tools**: OpenTelemetry in, Prometheus and Loki for storage, Grafana for dashboards.

## What It Includes

This repository is infrastructure and configuration, not an application codebase. The stack is driven by Docker Compose and `just` recipes.

- **Caddy** for TLS termination and routing.
- **OpenTelemetry Collector** for authenticated OTLP/gRPC ingestion.
- **Prometheus** for metrics storage.
- **Loki** for log storage.
- **Grafana** for file-provisioned dashboards.

Current dashboards cover cost, daily usage, waste, and efficiency. They are provisioned from `grafana/dashboards/` and tagged for Claude Code telemetry today.

## Supported Tools

| Tool | Status |
|---|---|
| Claude Code | Supported today |
| Codex | Planned |
| opencode | Planned |
| More AI agentic tools | Future roadmap |

The ingestion path is OpenTelemetry-first. New tools should integrate by emitting compatible OTLP metrics and logs with stable resource attributes such as developer and team identity.

## Architecture

```text
Developer machines
Claude Code today, more tools later
        |
        | OTLP/gRPC :4317
        | Bearer token auth + TLS
        v
      Caddy
        |
        | h2c
        v
OpenTelemetry Collector
        |
        +--> Prometheus metrics
        |
        +--> Loki logs

Grafana reads from Prometheus + Loki
```

Local development and production use the same base compose file. Local development adds an explicit override for local-only TLS and debug ports; production runs the base stack behind real DNS and Let's Encrypt certificates.

## Prerequisites

- Docker with the `docker compose` plugin
- [`just`](https://github.com/casey/just)
- `curl`, `jq`, `openssl`, and `python3` for smoke testing

## Quick Start: Local

Local setup uses `aimonitor.local` and Caddy's internal TLS CA.

1. Clone the repository and enter it:

   ```bash
   git clone https://github.com/<your-org>/ai-team-telemetry.git
   cd ai-team-telemetry
   ```

2. Create the local environment file:

   ```bash
   just setup
   ```

3. Generate a bearer token:

   ```bash
   just token
   ```

4. Edit `.env`:

   ```dotenv
   VPS_DOMAIN=aimonitor.local
   CADDY_EMAIL=dev@localhost
   OTEL_BEARER_TOKEN=<paste-token-from-just-token>
   GF_SECURITY_ADMIN_USER=admin
   GF_SECURITY_ADMIN_PASSWORD=admin
   ```

5. Add the local host entry:

   ```bash
   echo '127.0.0.1   aimonitor.local' | sudo tee -a /etc/hosts
   ```

6. Start the stack:

   ```bash
   just up
   ```

7. Trigger Caddy's local CA generation:

   ```bash
   curl -sk https://aimonitor.local/api/health
   ```

8. Trust the local CA on macOS:

   ```bash
   just trust-cert
   ```

   Add the printed `NODE_EXTRA_CA_CERTS` line to your shell profile. Node.js does not read the macOS System keychain, so Claude Code needs this environment variable for local TLS.

9. Run the smoke test:

   ```bash
   just smoke
   ```

10. Open Grafana:

    ```bash
    just open
    ```

Grafana is also available directly at `http://localhost:3000` in local development.

## Production: VPS

Production is designed for a single VPS with DNS pointing at the host.

1. Create an `A` record such as `monitor.yourdomain.com` pointing to the VPS IP.
2. Install Docker, the `docker compose` plugin, and `just`.
3. Clone the repository on the VPS.
4. Run setup:

   ```bash
   just setup
   ```

5. Edit `.env`:

   ```dotenv
   VPS_DOMAIN=monitor.yourdomain.com
   CADDY_EMAIL=you@yourdomain.com
   OTEL_BEARER_TOKEN=<strong-token-from-just-token>
   GF_SECURITY_ADMIN_USER=admin
   GF_SECURITY_ADMIN_PASSWORD=<strong-password>
   ```

6. Open the required inbound ports:

   ```bash
   ufw allow 80,443,4317/tcp
   ```

7. Start the production stack:

   ```bash
   just up-prod
   ```

8. Check service state:

   ```bash
   just ps
   ```

9. Verify Grafana health through Caddy:

   ```bash
   curl -sI https://monitor.yourdomain.com/api/health
   ```

Grafana is available at `https://monitor.yourdomain.com`. OTLP telemetry should be sent to `https://monitor.yourdomain.com:4317`.

## Claude Code Client Configuration

Each developer should export these values in their shell profile. Replace `<ENDPOINT>` with `https://aimonitor.local:4317` locally or `https://monitor.yourdomain.com:4317` in production. Replace `<TOKEN>` with `OTEL_BEARER_TOKEN`.

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=<ENDPOINT>
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <TOKEN>"
export OTEL_RESOURCE_ATTRIBUTES="developer.name=<your-name>,team=<team-name>"
```

For local development on macOS, also add the `NODE_EXTRA_CA_CERTS` line printed by:

```bash
just trust-cert
```

## Operating The Stack

| Command | Purpose |
|---|---|
| `just` | List all recipes |
| `just setup` | Create `.env` from `.env.example` if needed |
| `just token` | Generate a random bearer token |
| `just up` | Start the local stack with the local override |
| `just up-prod` | Start the production stack |
| `just down` | Stop the stack and keep volumes |
| `just reset` | Stop the stack and delete all data volumes |
| `just reload` | Recreate containers after config changes |
| `just ps` | Show container health and state |
| `just logs [service]` | Tail all logs or one service |
| `just ping` | Check Caddy routing and TLS on `:443` and `:4317` |
| `just smoke` | Run the local smoke test |
| `just validate` | Validate compose and collector configuration |
| `just clean-data` | Wipe Prometheus and Loki data while keeping Grafana users and Caddy CA |
| `just metrics` | List Claude-related metric names from Prometheus |

## Retention

- Prometheus: **14 days** or **80 GB**, configured in `docker-compose.yml`
- Loki: **120 hours**, configured in `loki/loki-config.yaml`

## Configuration Notes

- OTLP ingestion is exposed through Caddy on `:4317`.
- The collector accepts OTLP/gRPC only; there is no OTLP/HTTP receiver.
- Ingestion requires bearer-token authentication.
- Metrics are exported from the collector to Prometheus through remote write.
- Logs are exported from the collector to Loki.
- Grafana datasources and dashboards are file-provisioned from `grafana/provisioning/` and `grafana/dashboards/`.

## Roadmap

- Add Codex telemetry support.
- Add opencode telemetry support.
- Generalize dashboards beyond Claude Code naming.
- Document the integration contract for additional AI agentic tools.
- Add project screenshots once dashboard visuals are ready.

## Project Status

This is an early open-source project. The current stack is usable for Claude Code telemetry and intentionally keeps the deployment model simple: Docker Compose, one domain, one OTLP endpoint, and standard observability components.

## License

Apache-2.0.

## Further Reading

- `AGENTS.md` for repo conventions and operational notes.
- `docs/superpowers/specs/2026-04-20-local-prod-parity-design.md` for the local and production parity design.
