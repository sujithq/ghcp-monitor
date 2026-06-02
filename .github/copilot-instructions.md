# Copilot instructions: ai-monitor

This repo runs a local **OpenTelemetry Collector** (in Docker) that receives OTLP
telemetry from GitHub Copilot (VS Code Chat + `gh copilot` CLI) and exports it to
**Azure Application Insights**.

## Architecture (the whole system)

```
Copilot Chat / gh copilot ──OTLP──▶ otelcol-contrib (Docker, :4317 gRPC / :4318 HTTP)
                                        └── azuremonitor exporter ──▶ App Insights
```

- `startService.ps1` — lifecycle manager wrapping `docker compose` (start/stop/restart/status/logs).
- `docker-compose.yml` — the collector service definition (image tag, ports, mount, restart policy).
- `otel-collector-config.yaml` — collector pipeline (otlp receiver → azuremonitor exporter).
- `README.md` — the human runbook; keep it in sync with any behavior change.

## Hard rules

- **Never commit secrets.** The App Insights connection string is fetched at
  runtime via `az cli` and passed as an in-memory env var. It must never be
  written to a tracked file.
- **Never commit real resource identifiers.** Subscription IDs, resource group
  names, App Insights App IDs, and connection strings must stay as
  `<placeholders>` in docs. This repo is public.
- Use the **contrib** collector image only (`opentelemetry-collector-contrib`);
  the core image lacks the `azuremonitor` exporter.
- The image tag is pinned in `docker-compose.yml` and updated via Dependabot
  (`docker-compose` ecosystem). Do not hardcode image tags elsewhere.
- Keep ports `4317` (gRPC) and `4318` (HTTP) — Copilot clients target these on
  `localhost`.

## Conventions

- PowerShell: pass `-ErrorAction Stop`, use approved verbs, no aliases in scripts.
- Keep `startService.ps1` idempotent and self-contained (no external modules).
- When you change script behavior or commands, update the matching `README.md`
  section in the same change.

## Validate before finishing

- Lint PowerShell: `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1`
- Lint Markdown: `markdownlint **/*.md` (if available)
- Confirm no secrets/IDs leaked: search for `subscriptions/`, `InstrumentationKey`,
  `connectionString` and ensure only placeholders remain.
