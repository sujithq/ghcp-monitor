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
  - gRPC `0.0.0.0:4317` (commented out, optional)
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

The collector runs as a detached Docker container defined in `docker-compose.yml`
and managed by `startService.ps1`. It uses the **contrib** image (contains the
`azuremonitor` exporter) and sets `restart: unless-stopped`, so it keeps running
after the terminal closes and auto-starts when Docker/Windows boots.

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
  `APPLICATIONINSIGHTS_CONNECTION_STRING` if already set), then passes it to
  Compose as an environment variable — the secret is never written to disk.
- Wraps `docker compose up -d` / `down`, so the container definition lives in
  version control and the image tag is updatable by Dependabot.

The collector image tag is pinned in `docker-compose.yml`. Dependabot opens
weekly pull requests to bump it (see `.github/dependabot.yml`).

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
  - port 4318 is published
  - endpoint is `http://localhost:4318`
  - connection string matches the target App Insights resource

## 10) Deploy to Azure Container Apps with GitHub Actions

The [deployment workflow](.github/workflows/deploy-azure.yml) runs manually from
`main`. It reuses your existing Application Insights component and its region.
The local Docker setup remains available and is not modified by deployment.

```text
Copilot Chat / CLI --> HTTPS :443 --> Container Apps ingress --> OTLP HTTP :4318
                                      IPv4 allowlist                |
                                                             App Insights
```

[Bicep](infra/main.bicep) reads the collector image from `docker-compose.yml`
and supplies `otel-collector-config.yaml` through `--config=env:OTELCOL_CONFIG`.
There is no custom image, Azure Container Registry, or file share to maintain.
The runtime connection string is fetched through Azure CLI after OIDC login,
masked, passed as a secure deployment parameter, and referenced through a
Container Apps secret. It is not stored in GitHub, parameter artifacts, step
outputs, or tracked files. OIDC authenticates deployment, not telemetry export.

### One-time Azure and GitHub setup

1. Identify the subscription containing your existing resource group and
   Application Insights component. Confirm that its region supports Container
   Apps, sufficient quota is available for deployment revision overlap, and
   your Azure policies allow this public, IP-restricted configuration. Check
   the estimated regional cost before provisioning anything.
2. Have an authorized subscription operator register `Microsoft.App`,
   `Microsoft.OperationalInsights`, and `Microsoft.ManagedIdentity` if needed.
   The workflow does not register providers, create resource groups, change
   Application Insights authentication, or switch to a different region.
3. Create a dedicated **user-assigned managed identity** for GitHub deployments.
   Grant it **Contributor** on the target resource group only. The operator
   doing this bootstrap needs identity-creation and role-assignment permissions;
   the workflow identity does not need Owner or role-assignment privileges.
4. In GitHub, create an Environment named **azure**. Under deployment branches
   and tags, select only the `main` branch, not a tag named `main`. Protect
   `main` with required CI/review checks. Add an Environment required reviewer
   when an appropriate reviewer is available.
5. On the Azure identity, add a federated credential for **GitHub Actions**,
   using the exact repository owner/name and the **Environment** entity `azure`.
   The issuer is `https://token.actions.githubusercontent.com`, the audience is
   `api://AzureADTokenExchange`, and the case-sensitive subject is
   `repo:<owner>/<repository>:environment:azure`. Leave optional numeric GitHub
   owner/repository IDs unset unless your repository deliberately uses a custom
   OIDC subject template.
6. Configure the Environment secrets and variables below. Do not put their
   actual values in this public repository. No Azure client secret is needed.

Environment **secrets**:

| Name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Deployment identity client ID |
| `AZURE_TENANT_ID` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing the target resource group |

Environment **variables**:

| Name | Value |
| --- | --- |
| `AZURE_RESOURCE_GROUP` | Existing target resource group |
| `APPINSIGHTS_NAME` | Existing Application Insights component in that group |
| `CONTAINER_APP_NAME` | Collector app name, 2-32 lowercase characters |
| `CONTAINER_APP_ENVIRONMENT_NAME` | Explicit Container Apps environment name |
| `ALLOWED_IP_CIDRS` | JSON array such as `["<public-ip>/32"]`, replaced with your actual egress IPv4 CIDRs |
| `REUSE_CONTAINER_APP_ENVIRONMENT` | `true` to reference an existing environment; otherwise `false` |
| `LOG_ANALYTICS_WORKSPACE_NAME` | Explicit workspace name; required unless reusing the environment |
| `REUSE_LOG_ANALYTICS_WORKSPACE` | `true` to reference an existing workspace; otherwise `false` |
| `LOG_ANALYTICS_RESOURCE_GROUP` | Existing workspace's group; defaults to the deployment group |

Choose unused names for a new environment/workspace, or explicitly enable
reuse. After creation, keep those settings unchanged for repeat deployments.
The workflow refuses to overwrite same-named resources not tagged as managed
by this repository. Reusing an environment leaves its configuration unchanged;
it must be public, in the App Insights region, with a Consumption workload
profile named `Consumption`. Reusing a workspace does not change its settings.
A new workspace is pay-as-you-go with 30-day retention. New workspaces can only
be created in the deployment resource group.

For a reused workspace outside that group, an operator must separately grant
the deployment identity workspace-read and shared-key-read permissions at that
workspace's scope. Do not broaden its Contributor role to the subscription.
The existing Application Insights resource and its workspace association are
never recreated or updated.

The IP allowlist accepts canonical IPv4 CIDRs with prefixes `1-32`; a single
address normally uses `/32`. It rejects missing/empty lists, malformed values,
IPv6, `0.0.0.0/0`, and networks starting at the unspecified address `0.0.0.0`.
All rules are `Allow`, so other source IPs are denied.
Use the actual public egress IP, including any corporate proxy or VPN, not
your machine's private address. IP restrictions are network access control,
not per-user authentication: other clients sharing an allowed egress can send
telemetry. Keep the allowlist narrow.

`0.0.0.0/32` means only the unspecified address `0.0.0.0`; it does not mean
"allow everyone" and cannot match your client's public IP. Replace it in the
GitHub **azure** Environment's `ALLOWED_IP_CIDRS` variable with
`["<your-actual-public-ip>/32"]`, using your real egress IPv4 address, then rerun
**plan**. Enter the JSON array, not a bare CIDR. The wildcard range would be
`0.0.0.0/0`, which this IP-restricted deployment deliberately forbids.

### Preview, approve, and deploy

1. Merge the workflow, infrastructure, and configuration into `main` after CI
   passes. Open **Actions > Deploy collector to Azure > Run workflow** and
   select `main` with operation **plan**.
2. Review the successful run's commit SHA, region, and resource-change summary.
   This runs the reusable CI checks, OIDC login, preflight, Azure deployment
   validation, and a resource-only what-if. It makes no Azure resource changes.
3. Confirm regional capacity, permissions, applicable policy, and estimated
   cost. A successful template validation does not guarantee capacity or prove
   end-to-end telemetry delivery. Obtain approval for any existing environment
   or workspace reuse before continuing.
4. Run the workflow again on `main` with operation **deploy**, the full reviewed
   commit SHA, and **prerequisites_confirmed** checked. The run refuses a SHA
   mismatch; if `main` changed, run and review a new plan first. Changes to
   GitHub Environment settings also require a new plan and review.
5. After any configured Environment approval, the job repeats validation,
   deploys incrementally, and waits up to ten minutes for the exact new
   revision to be ready. The run summary includes the HTTPS endpoint, image,
   and ready revision. Deployments are serialized and do not cancel an active
   deployment when another run is requested.

Only the Azure job receives `id-token: write`. Pull requests and the reusable
lint workflow do not receive Azure credentials. Azure Login is pinned to the
published v3.1.0 commit; Dependabot maintains GitHub Actions references.
Merged collector image updates also need a manual plan/deploy run.

The app uses one always-on replica (`minReplicas: 1`, `maxReplicas: 1`),
`0.25` vCPU, `0.5Gi` memory, single active-revision mode, TCP health probes on
`4318`, and a 60-second termination grace period. It is a personal/light-use
baseline, not a highly available or durably buffered collector. Restart or
outage can lose in-memory telemetry. Budget for active/idle Consumption
compute, logging, App Insights ingestion, and applicable egress. Free grants
are shared across the subscription; always-on does not mean free.

The [CI parameter file](infra/main.bicepparam) has non-deployable placeholder
defaults for editor use. The workflow validates real Environment values
before login and supplies the runtime parameters in one process. Do not
compile or upload resolved parameter files containing live credentials, enable
debug tracing, or dump raw Azure resource/what-if payloads to public logs.
CLI failures intentionally withhold raw output; inspect the deployment or
activity log in the Azure portal using your authorized account.

### Verify and switch clients

Keep the local endpoint until cloud ingestion is verified. From an allowlisted
network, set the following VS Code user settings, using the workflow endpoint
without a `:4318` suffix:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container-app-fqdn>",
  "github.copilot.chat.otel.captureContent": false
}
```

For the Copilot CLI, use the same HTTPS base URL:

```powershell
$env:OTEL_EXPORTER_OTLP_ENDPOINT = 'https://<container-app-fqdn>'
$env:OTEL_EXPORTER_OTLP_PROTOCOL = 'http/protobuf'
gh copilot -p "Respond with exactly: OTEL_CLI_PROBE_OK"
```

Prompt/code capture should remain opt-in. Review data handling, retention,
and access before enabling it. Generate a new Copilot Chat request as well,
then use the App Insights queries in sections 6 and 7 to verify recent
`copilot-chat` and `github-copilot` telemetry. Check new timestamps, not just
historical counts.

To exercise all three OTLP HTTP routes independently, run this synthetic
JSON probe from an allowed network:

```powershell
$endpoint = 'https://<container-app-fqdn>'
$probe = 'aca-probe-' + [guid]::NewGuid().ToString('N')
$start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000
$end = $start + 1000000
$resource = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'collector-probe' } }) }
$payloads = @{
    traces = @{ resourceSpans = @(@{
        resource = $resource
        scopeSpans = @(@{ spans = @(@{
            traceId = [guid]::NewGuid().ToString('N')
            spanId = [guid]::NewGuid().ToString('N').Substring(0, 16)
            name = $probe
            kind = 1
            startTimeUnixNano = [string]$start
            endTimeUnixNano = [string]$end
        }) })
    }) }
    metrics = @{ resourceMetrics = @(@{
        resource = $resource
        scopeMetrics = @(@{ metrics = @(@{
            name = $probe
            gauge = @{ dataPoints = @(@{ timeUnixNano = [string]$end; asDouble = 1 }) }
        }) })
    }) }
    logs = @{ resourceLogs = @(@{
        resource = $resource
        scopeLogs = @(@{ logRecords = @(@{
            timeUnixNano = [string]$end
            severityNumber = 9
            body = @{ stringValue = $probe }
        }) })
    }) }
}
foreach ($signal in $payloads.Keys) {
    $body = $payloads[$signal] | ConvertTo-Json -Depth 20 -Compress
    Invoke-RestMethod -Uri "$endpoint/v1/$signal" -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop
}
Write-Output "App Insights probe name: $probe"
```

Check each response for partial rejection and confirm all three signal types
arrive in App Insights after its ingestion delay. Use the emitted probe name:

```kusto
union dependencies, customMetrics, traces
| where timestamp > ago(30m)
| where name == '<probe-name>' or message == '<probe-name>'
| summarize count() by itemType
```

From a known non-allowlisted network, requests must be rejected, normally with
HTTP `403`. GitHub-hosted runner addresses are not automatically allowlisted:
the workflow verifies readiness through Azure's control plane, and positive
ingestion testing belongs on your allowed network. Do not open ingress for
CI smoke tests. OTLP does not provide an HTTP health page at `/`.

### Operations and rollback

- Use the Container App's **Revisions and replicas**, **Log stream**, and
  associated Log Analytics workspace for status and failures. The local
  `startService.ps1` status/logs commands still refer only to Docker.
- When your public IP changes, update `ALLOWED_IP_CIDRS`, then review a new
  plan and deploy. Do not temporarily remove all IP restrictions.
- To refresh the App Insights connection string, run plan/deploy again. Each
  deployment gets a commit/run/attempt revision suffix so new replicas consume
  the refreshed secret. Changing an app-scoped secret alone does not restart
  existing revisions.
- To roll back, revert the deployment-affecting changes on `main`, then run a
  new plan/deploy. Activating an old revision alone does not roll back
  app-scoped secrets or ingress rules. Restore those through the reviewed
  configuration too.
- To fall back locally, restore `http://localhost:4318` in both clients and
  start the local collector. Azure resources continue billing until managed
  separately; never delete the shared resource group, existing App Insights,
  or reused workspace as a cleanup shortcut.

### Local deployment checks

PowerShell 7.4 or newer is required for deployment helper tests. These checks
do not authenticate to Azure or deploy resources:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -ErrorAction Stop
Invoke-Pester -Path ./.github/tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -ErrorAction Stop
Invoke-ScriptAnalyzer -Path ./.github/scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -ErrorAction Stop
```

CI additionally compiles Bicep, checks workflow syntax, validates the pinned
collector with synthetic credentials and no container network access, lints
Markdown, and scans for secrets. The existing image and collector config must
match their compiled infrastructure values.

References: [Azure OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect),
[Container Apps IP restrictions](https://learn.microsoft.com/azure/container-apps/ip-restrictions),
[Container Apps secrets](https://learn.microsoft.com/azure/container-apps/manage-secrets),
and [collector configuration providers](https://opentelemetry.io/docs/collector/configuration/).
