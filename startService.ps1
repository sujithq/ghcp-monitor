[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs')]
    [string]$Action = 'start'
)

$ErrorActionPreference = 'Stop'

$ContainerName = 'ai-monitor-otelcol'
$ComposeFile = Join-Path $PSScriptRoot 'docker-compose.yml'
$AppInsightsName = 'ai-monitor'
$AppInsightsResourceGroup = 'rg-monitor-ai'

function Invoke-Compose {
    param([Parameter(Mandatory)][string[]]$ComposeArgs)
    # Compose interpolates APPLICATIONINSIGHTS_CONNECTION_STRING for every command
    # (ps/down/logs included). Only container creation (up) needs the real value,
    # which Start-CollectorService sets. Provide a placeholder otherwise so
    # read-only and teardown commands don't require an az lookup or sign-in.
    if (-not $env:APPLICATIONINSIGHTS_CONNECTION_STRING) {
        $env:APPLICATIONINSIGHTS_CONNECTION_STRING = 'unset'
    }
    & docker compose -f $ComposeFile @ComposeArgs
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') failed (exit $LASTEXITCODE)." }
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
    if (-not (Test-Path $ComposeFile)) {
        throw "Compose file not found: $ComposeFile"
    }
    $env:APPLICATIONINSIGHTS_CONNECTION_STRING = Get-ConnectionString

    Write-Host "Starting background collector '$ContainerName' (auto-restart enabled)..."
    try {
        Invoke-Compose @('up', '-d')
    }
    catch {
        # A container with this name may exist from a previous non-Compose run.
        # Remove it and retry once so Compose can manage it.
        Write-Host "Compose up failed; removing any conflicting container '$ContainerName' and retrying..."
        & docker rm -f $ContainerName 2>$null | Out-Null
        Invoke-Compose @('up', '-d')
    }
    Write-Host "Started. Listening on OTLP gRPC :4317 and HTTP :4318."
    Write-Host "It will auto-start with Docker on boot. Stop with: .\startService.ps1 stop"
}

function Stop-CollectorService {
    Write-Host "Stopping and removing '$ContainerName'..."
    Invoke-Compose @('down')
    Write-Host "Stopped."
}

function Show-Status {
    Invoke-Compose @('ps')
}

switch ($Action) {
    'start' { Start-CollectorService }
    'stop' { Stop-CollectorService }
    'restart' { Stop-CollectorService; Start-CollectorService }
    'status' { Show-Status }
    'logs' { Invoke-Compose @('logs', '-f') }
}