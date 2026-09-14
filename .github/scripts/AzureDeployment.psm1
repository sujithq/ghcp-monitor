Set-StrictMode -Version Latest

function Get-RequiredDeploymentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Variables,
        [Parameter(Mandatory)][string]$Name
    )

    $value = [string]$Variables[$Name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[<>\r\n]' -or $value -eq 'unset') {
        throw "Configure $Name in the GitHub azure environment before running this workflow."
    }
    return $value
}

function Get-CollectorDeploymentSetting {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'deploy')][string]$Operation = 'plan',
        [string]$ReviewedSha = '',
        [bool]$PrerequisitesConfirmed = $false,
        [System.Collections.IDictionary]$Variables = [System.Environment]::GetEnvironmentVariables()
    )

    if ($Variables['GITHUB_ACTIONS'] -ne 'true' -or $Variables['GITHUB_REF'] -cne 'refs/heads/main') {
        throw 'Deployment runs only through GitHub Actions on refs/heads/main.'
    }

    $settings = @{}
    foreach ($name in @(
            'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP',
            'APPINSIGHTS_NAME', 'CONTAINER_APP_NAME', 'CONTAINER_APP_ENVIRONMENT_NAME',
            'ALLOWED_IP_CIDRS', 'GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'
        )) {
        $settings[$name] = Get-RequiredDeploymentValue -Variables $Variables -Name $name
    }

    foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')) {
        $identifier = [guid]::Empty
        if (-not [guid]::TryParse($settings[$name], [ref]$identifier) -or $identifier -eq [guid]::Empty) {
            throw "$name must contain the configured Azure identifier."
        }
    }

    $commit = $settings.GITHUB_SHA
    if ($commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'GITHUB_SHA must be the full commit SHA.'
    }
    if ($Operation -eq 'deploy') {
        if ($ReviewedSha -cne $commit) {
            throw 'The reviewed commit SHA must exactly match the dispatched main commit. Run plan again after any change.'
        }
        if (-not $PrerequisitesConfirmed) {
            throw 'Confirm regional capacity, policy, permissions, and estimated cost before deploying.'
        }
    }

    if ($settings.CONTAINER_APP_NAME -cnotmatch '^[a-z][a-z0-9-]{0,30}[a-z0-9]$' -or $settings.CONTAINER_APP_NAME.Contains('--')) {
        throw 'CONTAINER_APP_NAME must be 2-32 lowercase letters, digits, or single hyphens, starting with a letter.'
    }
    if ($settings.CONTAINER_APP_ENVIRONMENT_NAME -cnotmatch '^[a-z][a-z0-9-]{0,58}[a-z0-9]$') {
        throw 'CONTAINER_APP_ENVIRONMENT_NAME must be 2-60 lowercase letters, digits, or hyphens, starting with a letter.'
    }
    if ($settings.GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or $settings.GITHUB_RUN_ATTEMPT -notmatch '^[1-9][0-9]*$') {
        throw 'GitHub run ID and attempt must be positive integers.'
    }
    $revisionSuffix = "r-$($commit.Substring(0, 7))-$($settings.GITHUB_RUN_ID)-$($settings.GITHUB_RUN_ATTEMPT)"
    if ($revisionSuffix.Length -gt 30) {
        throw 'The generated revision suffix exceeds 30 characters.'
    }

    try {
        $cidrs = ConvertFrom-Json -InputObject $settings.ALLOWED_IP_CIDRS -NoEnumerate -ErrorAction Stop
    }
    catch {
        throw 'ALLOWED_IP_CIDRS must be a JSON array of approved public IPv4 CIDRs.'
    }
    if ($cidrs -isnot [array] -or $cidrs.Count -eq 0) {
        throw 'ALLOWED_IP_CIDRS must be a nonempty JSON array; empty rules would allow all traffic.'
    }
    foreach ($cidr in $cidrs) {
        $network = [System.Net.IPNetwork]::new([System.Net.IPAddress]::Any, 0)
        if ($cidr -isnot [string] -or
            -not [System.Net.IPNetwork]::TryParse($cidr, [ref]$network) -or
            $network.BaseAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
            $network.PrefixLength -eq 0 -or $network.ToString() -cne $cidr) {
            throw 'ALLOWED_IP_CIDRS must contain canonical IPv4 CIDRs with prefixes 1-32; unrestricted ranges are forbidden.'
        }
        if ($network.BaseAddress.Equals([System.Net.IPAddress]::Any)) {
            throw 'ALLOWED_IP_CIDRS cannot use a network starting at 0.0.0.0. 0.0.0.0/32 is not a wildcard; use your actual public egress IPv4 address followed by /32.'
        }
    }

    foreach ($name in @('REUSE_CONTAINER_APP_ENVIRONMENT', 'REUSE_LOG_ANALYTICS_WORKSPACE')) {
        $value = [string]$Variables[$name]
        if ([string]::IsNullOrEmpty($value)) { $value = 'false' }
        if ($value -notin @('true', 'false')) {
            throw "$name must be true or false."
        }
        $settings[$name] = $value.ToLowerInvariant()
    }
    $settings.LOG_ANALYTICS_WORKSPACE_NAME = [string]$Variables['LOG_ANALYTICS_WORKSPACE_NAME']
    $settings.LOG_ANALYTICS_RESOURCE_GROUP = [string]$Variables['LOG_ANALYTICS_RESOURCE_GROUP']
    if ([string]::IsNullOrEmpty($settings.LOG_ANALYTICS_RESOURCE_GROUP)) {
        $settings.LOG_ANALYTICS_RESOURCE_GROUP = $settings.AZURE_RESOURCE_GROUP
    }
    if ($settings.REUSE_CONTAINER_APP_ENVIRONMENT -eq 'false') {
        $settings.LOG_ANALYTICS_WORKSPACE_NAME = Get-RequiredDeploymentValue -Variables $Variables -Name 'LOG_ANALYTICS_WORKSPACE_NAME'
        if ($settings.REUSE_LOG_ANALYTICS_WORKSPACE -eq 'false' -and $settings.LOG_ANALYTICS_RESOURCE_GROUP -ne $settings.AZURE_RESOURCE_GROUP) {
            throw 'New Log Analytics workspaces must be created in AZURE_RESOURCE_GROUP.'
        }
    }
    $settings.REVISION_SUFFIX = $revisionSuffix
    return $settings
}

function Get-AzureFailureDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $candidate = $Text.Trim() -replace '^ERROR:\s*', ''
    $details = [System.Collections.Generic.List[string]]::new()
    try {
        $response = ConvertFrom-Json -InputObject $candidate -AsHashtable -ErrorAction Stop
        if ($response -is [System.Collections.IDictionary]) {
            $pending = [System.Collections.Generic.Queue[object]]::new()
            $pending.Enqueue($(if ($response.Contains('error')) { $response['error'] } else { $response }))
            while ($pending.Count -gt 0 -and $details.Count -lt 5) {
                $errorDetail = $pending.Dequeue()
                if ($errorDetail -isnot [System.Collections.IDictionary]) { continue }
                if ([string]$errorDetail['code'] -cmatch '^[A-Za-z][A-Za-z0-9_.-]{0,79}$') {
                    $details.Add("$($errorDetail['code']): $($errorDetail['message'])")
                }
                foreach ($child in $errorDetail['details']) { $pending.Enqueue($child) }
            }
        }
    }
    catch {
        $standardError = [regex]::Match($candidate, '^\((?<code>[A-Za-z][A-Za-z0-9_.-]{0,79})\)\s*(?<message>[^\r\n]*)')
        if ($standardError.Success) {
            $details.Add("$($standardError.Groups['code'].Value): $($standardError.Groups['message'].Value)")
        }
    }

    $safeDetail = $details -join ' | '
    foreach ($name in @(
            'APPLICATIONINSIGHTS_CONNECTION_STRING', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID'
        )) {
        $value = [System.Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrEmpty($value)) { $safeDetail = $safeDetail.Replace($value, '<redacted>') }
    }
    $safeDetail = $safeDetail -replace '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<redacted-id>'
    $safeDetail = $safeDetail -replace '(?i)(\b[\w-]*(?:connectionstring|instrumentationkey|sharedkey|accesskey|accountkey|password|secret|token|sig)\b["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s;,]+)', '$1<redacted>'
    $safeDetail = $safeDetail -replace '(?i)\bBearer\s+\S+', 'Bearer <redacted>'
    $safeDetail = $safeDetail -replace '[\r\n]+', ' '
    if ($safeDetail.Length -gt 1500) { $safeDetail = $safeDetail.Substring(0, 1500) + '...' }
    return $safeDetail
}

function Invoke-AzureJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $commandOutput = @(& az @Arguments --only-show-errors --output json 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
        $commandLength = if ($Arguments[0] -eq 'deployment') { 3 } else { 2 }
        $commandName = ($Arguments | Select-Object -First $commandLength) -join ' '
        $detail = Get-AzureFailureDetail -Text ($commandOutput -join "`n")
        throw "Azure CLI $commandName failed (exit $exitCode). $detail Raw output is withheld to protect credentials; inspect Azure deployment or activity logs."
    }
    if ($commandOutput.Count -eq 0) { return $null }
    try {
        return ConvertFrom-Json -InputObject ($commandOutput -join "`n") -AsHashtable -ErrorAction Stop
    }
    catch {
        throw 'Azure CLI returned unexpected output; details are withheld to protect credentials.'
    }
}

function Assert-DeploymentResourceOwnership {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Resources,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repository
    )

    foreach ($resource in @($Resources | Where-Object { $_.type -eq $Type -and $_.name -eq $Name })) {
        if (-not $resource.tags -or $resource.tags['managed-by'] -ne 'github-actions' -or $resource.tags['repository'] -ne $Repository) {
            throw "Refusing to overwrite $Type '$Name': it is not managed by this repository. Choose another name or explicitly reuse the supporting resource."
        }
    }
}

function Invoke-CollectorDeployment {
    [CmdletBinding()]
    param(
        [ValidateSet('plan', 'deploy')][string]$Operation = 'plan',
        [string]$ReviewedSha = '',
        [bool]$PrerequisitesConfirmed = $false
    )

    $settings = Get-CollectorDeploymentSetting -Operation $Operation -ReviewedSha $ReviewedSha -PrerequisitesConfirmed $PrerequisitesConfirmed
    $account = Invoke-AzureJson -Arguments @('account', 'show', '--query', '{id:id,tenantId:tenantId}')
    if ($account.id -ne $settings.AZURE_SUBSCRIPTION_ID -or $account.tenantId -ne $settings.AZURE_TENANT_ID) {
        throw 'Azure login does not match the configured subscription and tenant.'
    }

    $provider = Invoke-AzureJson -Arguments @(
        'provider', 'show', '--namespace', 'Microsoft.App', '--query',
        "{state:registrationState,locations:resourceTypes[?resourceType=='managedEnvironments'].locations | [0]}"
    )
    if ($provider.state -ne 'Registered') {
        throw 'Register Microsoft.App during the one-time Azure bootstrap, then rerun plan.'
    }

    $insights = Invoke-AzureJson -Arguments @(
        'resource', 'show', '--resource-group', $settings.AZURE_RESOURCE_GROUP,
        '--name', $settings.APPINSIGHTS_NAME, '--resource-type', 'Microsoft.Insights/components',
        '--api-version', '2020-02-02', '--query',
        '{location:location,connectionString:properties.ConnectionString,disableLocalAuth:properties.DisableLocalAuth,ingestionAccess:properties.publicNetworkAccessForIngestion}'
    )
    $connectionString = [string]$insights.connectionString
    if (-not [string]::IsNullOrEmpty($connectionString)) {
        $mask = $connectionString.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "::add-mask::$mask"
    }
    $settings.APPLICATIONINSIGHTS_CONNECTION_STRING = Get-RequiredDeploymentValue -Variables @{ APPLICATIONINSIGHTS_CONNECTION_STRING = $connectionString } -Name 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    if ($insights.disableLocalAuth -eq $true -or $insights.ingestionAccess -eq 'Disabled') {
        throw 'Existing App Insights disables local authentication or public ingestion. This connection-string deployment cannot use it; its policy will not be changed.'
    }
    $settings.AZURE_LOCATION = ([string]$insights.location).Replace(' ', '').ToLowerInvariant()
    $supportedLocations = @($provider.locations | ForEach-Object { $_.Replace(' ', '').ToLowerInvariant() })
    if (-not $settings.AZURE_LOCATION -or $settings.AZURE_LOCATION -notin $supportedLocations) {
        throw 'Container Apps is not available in the existing App Insights region. No region fallback is performed.'
    }

    $resources = @(Invoke-AzureJson -Arguments @(
            'resource', 'list', '--resource-group', $settings.AZURE_RESOURCE_GROUP,
            '--query', '[].{name:name,type:type,tags:tags}'
        ))
    Assert-DeploymentResourceOwnership -Resources $resources -Type 'Microsoft.App/containerApps' -Name $settings.CONTAINER_APP_NAME -Repository $settings.GITHUB_REPOSITORY
    if ($settings.REUSE_CONTAINER_APP_ENVIRONMENT -eq 'true') {
        $existingEnvironment = Invoke-AzureJson -Arguments @(
            'resource', 'show', '--resource-group', $settings.AZURE_RESOURCE_GROUP,
            '--name', $settings.CONTAINER_APP_ENVIRONMENT_NAME, '--resource-type', 'Microsoft.App/managedEnvironments',
            '--api-version', '2025-01-01', '--query',
            '{location:location,internal:properties.vnetConfiguration.internal,publicNetworkAccess:properties.publicNetworkAccess,profiles:properties.workloadProfiles}'
        )
        $consumptionProfile = @($existingEnvironment.profiles | Where-Object { $_.name -eq 'Consumption' -and $_.workloadProfileType -eq 'Consumption' })
        if ($existingEnvironment.location.Replace(' ', '').ToLowerInvariant() -ne $settings.AZURE_LOCATION -or
            $existingEnvironment.internal -eq $true -or $existingEnvironment.publicNetworkAccess -eq 'Disabled' -or $consumptionProfile.Count -ne 1) {
            throw 'The selected environment must be public, in the App Insights region, and have a Consumption workload profile named Consumption.'
        }
    }
    else {
        Assert-DeploymentResourceOwnership -Resources $resources -Type 'Microsoft.App/managedEnvironments' -Name $settings.CONTAINER_APP_ENVIRONMENT_NAME -Repository $settings.GITHUB_REPOSITORY
        if ($settings.REUSE_LOG_ANALYTICS_WORKSPACE -eq 'false') {
            Assert-DeploymentResourceOwnership -Resources $resources -Type 'Microsoft.OperationalInsights/workspaces' -Name $settings.LOG_ANALYTICS_WORKSPACE_NAME -Repository $settings.GITHUB_REPOSITORY
        }
    }

    $parameterFile = Join-Path $PSScriptRoot '../../infra/main.bicepparam'
    $deploymentName = "collector-$($settings.REVISION_SUFFIX)"
    $deploymentArguments = @('--resource-group', $settings.AZURE_RESOURCE_GROUP, '--name', $deploymentName, '--parameters', $parameterFile, '--mode', 'Incremental')
    $previousEnvironment = @{}
    $parameterNames = @(
        'AZURE_LOCATION', 'AZURE_RESOURCE_GROUP', 'CONTAINER_APP_NAME', 'CONTAINER_APP_ENVIRONMENT_NAME',
        'REUSE_CONTAINER_APP_ENVIRONMENT', 'LOG_ANALYTICS_WORKSPACE_NAME', 'LOG_ANALYTICS_RESOURCE_GROUP',
        'REUSE_LOG_ANALYTICS_WORKSPACE', 'ALLOWED_IP_CIDRS', 'APPLICATIONINSIGHTS_CONNECTION_STRING',
        'REVISION_SUFFIX', 'GITHUB_REPOSITORY'
    )
    try {
        foreach ($name in $parameterNames) {
            $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            [System.Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
        }
        Write-Host 'Validating the resource-group deployment...'
        $null = Invoke-AzureJson -Arguments (@('deployment', 'group', 'validate') + $deploymentArguments)
        $preview = Invoke-AzureJson -Arguments (@('deployment', 'group', 'what-if') + $deploymentArguments + @('--result-format', 'ResourceIdOnly', '--no-pretty-print'))
        if ($preview.status -ne 'Succeeded' -or $preview.error) {
            throw 'Azure what-if did not succeed. No deployment will be performed.'
        }

        $summary = @(
            '## Collector deployment',
            "Operation: $Operation",
            "Reviewed commit: $($settings.GITHUB_SHA)",
            "Region: $($settings.AZURE_LOCATION)",
            "Deployment: $deploymentName",
            '',
            '| Change | Resource |',
            '| --- | --- |'
        )
        foreach ($change in $preview.changes) {
            $summary += "| $($change.changeType) | $($change.resourceId.Split('/')[-1]) |"
        }

        if ($Operation -eq 'deploy') {
            Write-Host 'Deploying the reviewed configuration...'
            $deployment = Invoke-AzureJson -Arguments (@('deployment', 'group', 'create') + $deploymentArguments + @('--query', 'properties.outputs'))
            $expectedRevision = "$($settings.CONTAINER_APP_NAME)--$($settings.REVISION_SUFFIX)"
            $null = Invoke-AzureJson -Arguments @(
                'resource', 'wait', '--name', $settings.CONTAINER_APP_NAME, '--resource-group', $settings.AZURE_RESOURCE_GROUP,
                '--resource-type', 'Microsoft.App/containerApps', '--api-version', '2025-01-01',
                '--custom', "properties.provisioningState=='Succeeded' && properties.latestRevisionName=='$expectedRevision' && properties.latestReadyRevisionName=='$expectedRevision'",
                '--interval', '10', '--timeout', '600'
            )
            $summary += @('', "Endpoint: $($deployment.endpoint.value)", "Image: $($deployment.image.value)", "Ready revision: $expectedRevision")
        }
        else {
            $summary += @('', 'No resources were changed. Review this commit, capacity, policy, and cost before dispatching deploy.')
        }
        Write-Host ($summary -join "`n")
        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8 -ErrorAction Stop
        }
    }
    finally {
        foreach ($name in $previousEnvironment.Keys) {
            if ($null -eq $previousEnvironment[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            else {
                [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
            }
        }
    }
}

Export-ModuleMember -Function Get-CollectorDeploymentSetting, Invoke-CollectorDeployment