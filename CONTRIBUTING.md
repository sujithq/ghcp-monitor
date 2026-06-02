# Contributing to ai-monitor

Thanks for your interest in improving this project. It is a small, focused
utility: a local OpenTelemetry Collector that forwards GitHub Copilot telemetry
to Azure Application Insights.

## Ground rules

- **Never commit secrets or real resource identifiers.** Connection strings,
  subscription IDs, resource group names, and App Insights App IDs must stay as
  `<placeholders>`. The runtime value is fetched via `az cli` and kept in memory.
- Keep `startService.ps1` self-contained and idempotent (no external modules).
- Use the **contrib** collector image (`opentelemetry-collector-contrib`); the
  core image lacks the `azuremonitor` exporter.
- When you change script behavior, update the matching section in `README.md`
  in the same pull request.

## Development setup

Prerequisites: Docker, Azure CLI (logged in), PowerShell 7+.

```powershell
# Start the collector in the background
./startService.ps1

# Check status / tail logs
./startService.ps1 status
./startService.ps1 logs
```

## Before opening a pull request

Run the linters locally:

```powershell
# PowerShell
Install-Module PSScriptAnalyzer -Scope CurrentUser   # first time only
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Markdown (requires Node)
npx markdownlint-cli2 "**/*.md"
```

Confirm no secrets leaked:

```powershell
git grep -nE "subscriptions/|InstrumentationKey|connectionString|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}"
```

## Commit and PR conventions

- Write clear, imperative commit messages ("Add status command", not "added").
- Keep pull requests focused; one logical change per PR.
- Describe what changed and how you verified it.

## Reporting issues

Use the issue templates. Never paste real connection strings or resource IDs
into an issue — redact them first.
