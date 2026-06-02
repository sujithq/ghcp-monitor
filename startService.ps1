[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs')]
    [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'

$ContainerName = 'ai-monitor-otelcol'
$Image = 'ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.153.0'
$ConfigPath = Join-Path $PSScriptRoot 'otel-collector-config.yaml'
$AppInsightsName = 'ai-monitor'
$AppInsightsResourceGroup = 'rg-monitor-ai'

function Test-Container {
    param([switch]$Running)
    $dockerArgs = @('ps', '-a', '--filter', "name=^/$ContainerName$", '--format', '{{.Names}}')
    if ($Running) { $dockerArgs += @('--filter', 'status=running') }
    $found = & docker @dockerArgs 2>$null
    return [bool]($found -eq $ContainerName)
}

function Get-ConnectionString {
    if ($env:APPLICATIONINSIGHTS_CONNECTION_STRING) {
        return $env:APPLICATIONINSIGHTS_CONNECTION_STRING
    }
    Write-Host "Retrieving Application Insights connection string for '$AppInsightsName' in '$AppInsightsResourceGroup' via az cli..."
    $cs = az monitor app-insights component show `
        --app $AppInsightsName `
        --resource-group $AppInsightsResourceGroup `
        --query connectionString `
        -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $cs) {
        throw "Failed to retrieve Application Insights connection string. Ensure you are signed in (az login) and have access to '$AppInsightsName' in '$AppInsightsResourceGroup'."
    }
    return $cs
}

function Start-CollectorService {
    if (Test-Container -Running) {
        Write-Host "Already running: '$ContainerName'."
        return
    }
    if (Test-Container) {
        Write-Host "Removing stale container '$ContainerName'..."
        docker rm -f $ContainerName | Out-Null
    }
    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }

    $cs = Get-ConnectionString

    Write-Host "Starting background collector '$ContainerName' (auto-restart enabled)..."
    docker run -d `
        --name $ContainerName `
        --restart unless-stopped `
        -p 4317:4317 -p 4318:4318 `
        -e APPLICATIONINSIGHTS_CONNECTION_STRING="$cs" `
        --mount "type=bind,source=$ConfigPath,target=/etc/otelcol-contrib/config.yaml" `
        $Image | Out-Null

    if ($LASTEXITCODE -ne 0) { throw "Failed to start container '$ContainerName'." }
    Write-Host "Started. Listening on OTLP gRPC :4317 and HTTP :4318."
    Write-Host "It will auto-start with Docker on boot. Stop with: .\startService.ps1 stop"
}

function Stop-CollectorService {
    if (-not (Test-Container)) {
        Write-Host "Not present: '$ContainerName'."
        return
    }
    Write-Host "Stopping and removing '$ContainerName'..."
    docker rm -f $ContainerName | Out-Null
    Write-Host "Stopped."
}

function Show-Status {
    docker ps -a --filter "name=^/$ContainerName$" `
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

switch ($Action) {
    'start' { Start-CollectorService }
    'stop' { Stop-CollectorService }
    'restart' { Stop-CollectorService; Start-CollectorService }
    'status' { Show-Status }
    'logs' { docker logs -f $ContainerName }
}