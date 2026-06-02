# Copilot Telemetry to Azure Monitor (OpenTelemetry Collector)

This runbook documents the exact setup used in this workspace to collect telemetry from:

- VS Code GitHub Copilot Chat
- GitHub Copilot CLI (`gh copilot`)

and export it to Azure Application Insights.

## 1) Prerequisites

- Docker installed and running
- Azure CLI installed and logged in
- Access to an Application Insights resource. Set these to your own values:
  - Resource ID: `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/microsoft.insights/components/<app-insights-name>`
  - App ID: `<app-insights-app-id>`

> The `startService.ps1` script defaults to an App Insights component named
> `ai-monitor` in resource group `rg-monitor-ai`. Edit the `$AppInsightsName`
> and `$AppInsightsResourceGroup` variables at the top of the script to match
> your environment.

## 2) VS Code Copilot Chat settings

In user `settings.json`, set:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "http://localhost:4318",
  "github.copilot.chat.otel.captureContent": true
}
```

Notes:

- Endpoint must be reachable from VS Code host: `http://localhost:4318`
- `captureContent: true` includes richer payload attributes in telemetry

## 3) Collector configuration

File: `otel-collector-config.yaml`

Current config uses:

- `otlp` receiver on:
  - HTTP `0.0.0.0:4318`
  - gRPC `0.0.0.0:4317`
- `azuremonitor` exporter reading connection string from env var:
  - `APPLICATIONINSIGHTS_CONNECTION_STRING`
- Debug exporter/logging currently commented out

You normally do not need to set the connection string manually — `startService.ps1`
retrieves it via `az cli` automatically. If you prefer to set it yourself (e.g.
to avoid an `az` call), export it before starting so the value is not typed as a
command:

```powershell
Read-Host -Prompt "Application Insights connection string" | ForEach-Object { $env:APPLICATIONINSIGHTS_CONNECTION_STRING = $_ }
```

## 4) Run collector as a local background service

The collector runs as a detached Docker container managed by `startService.ps1`.
It uses the **contrib** image (contains `azuremonitor` exporter) and starts with
`--restart unless-stopped`, so it keeps running after the terminal closes and
auto-starts when Docker/Windows boots.

Start it in the background:

```powershell
.\startService.ps1
```

Lifecycle commands:

```powershell
.\startService.ps1 start     # start in background (default)
.\startService.ps1 status    # show container status and ports
.\startService.ps1 logs      # tail collector logs (Ctrl+C to detach)
.\startService.ps1 restart   # recreate the container
.\startService.ps1 stop      # stop and remove the container
```

The script:

- Auto-retrieves the App Insights connection string via `az cli` (or reuses
  `APPLICATIONINSIGHTS_CONNECTION_STRING` if already set), so the secret is not
  typed on the command line or stored in PowerShell history.
- Is idempotent: re-running `start` will not double-launch; it cleans up any
  stale container named `ai-monitor-otelcol` first.

Important:

- Do not use core `opentelemetry-collector` image for this config.
- Port mapping is required so host processes can send OTLP to container.
- For true auto-start after reboot, enable **Start Docker Desktop when you log
  in** (Docker Desktop → Settings → General).

## 5) Optional debug mode

To inspect payloads live, uncomment in `otel-collector-config.yaml`:

- `exporters.debug`
- `service.telemetry.logs.level: debug`
- add `debug` to each pipeline exporters list

When done troubleshooting, comment these back out to reduce noise.

## 6) Verify ingestion in App Insights

Optionally set the target subscription (only if it differs from your default):

```powershell
az account set --subscription <subscription-id>
```

Quick count check:

```powershell
az monitor app-insights query --app <app-insights-app-id> --analytics-query "union dependencies, customMetrics, traces, requests, exceptions | where timestamp > ago(2h) | summarize count() by itemType" -o json
```

Interpretation used in this setup:

- `dependencies`: spans (many Copilot operations appear here)
- `customMetrics`: token usage and duration metrics
- `traces`: log events

## 7) Verify Copilot CLI telemetry

Run Copilot CLI with OTLP env vars in the same shell:

```powershell
$env:OTEL_EXPORTER_OTLP_ENDPOINT='http://localhost:4318'
$env:OTEL_EXPORTER_OTLP_PROTOCOL='http/protobuf'
gh copilot -p "Respond with exactly: OTEL_CLI_PROBE_OK"
```

Then query for CLI source:

```powershell
az monitor app-insights query --app <app-insights-app-id> --analytics-query "union dependencies, customMetrics, traces | where timestamp > ago(30m) and cloud_RoleName == 'github-copilot' | top 20 by timestamp desc | project timestamp, itemType, name, cloud_RoleName, customDimensions" -o json
```

Confirmed signal in this environment:

- `cloud_RoleName == github-copilot` (Copilot CLI)
- `cloud_RoleName == copilot-chat` (VS Code Copilot Chat)

## 8) Stop collector

Stop and remove the background service:

```powershell
.\startService.ps1 stop
```

Check status at any time:

```powershell
.\startService.ps1 status
```

## 9) Common gotchas

- App Insights dashboard may lag; Logs often show data first.
- End-to-end latency can be a few minutes.
- If no data appears, verify:
  - collector is running
  - ports 4317/4318 are published
  - endpoint is `http://localhost:4318`
  - connection string matches the target App Insights resource
