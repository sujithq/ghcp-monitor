BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AzureDeployment.psm1') -Force -ErrorAction Stop
}

Describe 'Collector deployment settings' {
    BeforeEach {
        $script:variables = @{
            GITHUB_ACTIONS = 'true'
            GITHUB_REF = 'refs/heads/main'
            GITHUB_SHA = 'a' * 40
            GITHUB_REPOSITORY = 'example/collector'
            GITHUB_RUN_ID = '123456'
            GITHUB_RUN_ATTEMPT = '1'
            AZURE_CLIENT_ID = [guid]::NewGuid().ToString()
            AZURE_TENANT_ID = [guid]::NewGuid().ToString()
            AZURE_SUBSCRIPTION_ID = [guid]::NewGuid().ToString()
            AZURE_RESOURCE_GROUP = 'test-resource-group'
            APPINSIGHTS_NAME = 'test-insights'
            CONTAINER_APP_NAME = 'test-collector'
            CONTAINER_APP_ENVIRONMENT_NAME = 'test-environment'
            LOG_ANALYTICS_WORKSPACE_NAME = 'test-logs'
            ALLOWED_IP_CIDRS = '["203.0.113.10/32","198.51.100.0/24"]'
        }
    }

    It 'accepts a read-only plan with an explicit allowlist' {
        $settings = Get-CollectorDeploymentSetting -Variables $variables
        $settings.ALLOWED_IP_CIDRS | Should -Be $variables.ALLOWED_IP_CIDRS
        $settings.REVISION_SUFFIX | Should -Be 'r-aaaaaaa-123456-1'
        $settings.REUSE_CONTAINER_APP_ENVIRONMENT | Should -Be 'false'
        $settings.LOG_ANALYTICS_RESOURCE_GROUP | Should -Be $variables.AZURE_RESOURCE_GROUP
    }

    It 'accepts deployment of the reviewed commit after prerequisite confirmation' {
        $settings = Get-CollectorDeploymentSetting -Variables $variables -Operation deploy -ReviewedSha $variables.GITHUB_SHA -PrerequisitesConfirmed $true
        $settings.GITHUB_SHA | Should -Be $variables.GITHUB_SHA
    }

    It 'rejects deployment of an unreviewed commit' {
        { Get-CollectorDeploymentSetting -Variables $variables -Operation deploy -ReviewedSha ('b' * 40) -PrerequisitesConfirmed $true } |
            Should -Throw '*reviewed commit SHA*'
    }

    It 'requires explicit prerequisite confirmation for deployment' {
        { Get-CollectorDeploymentSetting -Variables $variables -Operation deploy -ReviewedSha $variables.GITHUB_SHA } |
            Should -Throw '*estimated cost*'
    }

    It 'rejects execution outside GitHub Actions' {
        $variables.GITHUB_ACTIONS = 'false'
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*GitHub Actions*'
    }

    It 'rejects non-main refs: <Ref>' -ForEach @(
        @{ Ref = 'refs/heads/feature' }
        @{ Ref = 'refs/tags/main' }
        @{ Ref = 'refs/pull/1/merge' }
    ) {
        $variables.GITHUB_REF = $Ref
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*refs/heads/main*'
    }

    It 'rejects unsafe allowlists: <Value>' -ForEach @(
        @{ Value = '' }
        @{ Value = '[]' }
        @{ Value = 'null' }
        @{ Value = '{}' }
        @{ Value = '"203.0.113.10/32"' }
        @{ Value = '[null]' }
        @{ Value = '[12]' }
        @{ Value = '["0.0.0.0/0"]' }
        @{ Value = '["::/0"]' }
        @{ Value = '["2001:db8::/32"]' }
        @{ Value = '["203.0.113.1/33"]' }
        @{ Value = '["999.1.1.1/32"]' }
        @{ Value = '["203.0.113.1"]' }
        @{ Value = '["203.0.113.10/24"]' }
        @{ Value = '["<public-ip>/32"]' }
        @{ Value = 'not-json' }
    ) {
        $variables.ALLOWED_IP_CIDRS = $Value
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*ALLOWED_IP_CIDRS*'
    }

    It 'rejects unspecified source networks with public IP guidance: <Value>' -ForEach @(
        @{ Value = '["0.0.0.0/32"]' }
        @{ Value = '["0.0.0.0/8"]' }
        @{ Value = '["203.0.113.10/32","0.0.0.0/32"]' }
    ) {
        $variables.ALLOWED_IP_CIDRS = $Value
        { Get-CollectorDeploymentSetting -Variables $variables } |
            Should -Throw '*ALLOWED_IP_CIDRS*0.0.0.0/32 is not a wildcard*actual public egress IPv4 address*'
    }

    It 'rejects missing or placeholder required values: <Name>' -ForEach @(
        @{ Name = 'AZURE_SUBSCRIPTION_ID' }
        @{ Name = 'AZURE_RESOURCE_GROUP' }
        @{ Name = 'APPINSIGHTS_NAME' }
        @{ Name = 'CONTAINER_APP_NAME' }
        @{ Name = 'CONTAINER_APP_ENVIRONMENT_NAME' }
    ) {
        $variables[$Name] = '<placeholder>'
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw "*$Name*"
    }

    It 'rejects ambiguous reuse settings' {
        $variables.REUSE_CONTAINER_APP_ENVIRONMENT = 'yes'
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*true or false*'
    }

    It 'does not require a workspace when reusing an environment' {
        $variables.REUSE_CONTAINER_APP_ENVIRONMENT = 'true'
        $variables.Remove('LOG_ANALYTICS_WORKSPACE_NAME')
        $settings = Get-CollectorDeploymentSetting -Variables $variables
        $settings.REUSE_CONTAINER_APP_ENVIRONMENT | Should -Be 'true'
    }

    It 'requires a workspace name when managing an environment' {
        $variables.Remove('LOG_ANALYTICS_WORKSPACE_NAME')
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*LOG_ANALYTICS_WORKSPACE_NAME*'
    }

    It 'rejects creation of a workspace outside the deployment resource group' {
        $variables.LOG_ANALYTICS_RESOURCE_GROUP = 'other-test-group'
        { Get-CollectorDeploymentSetting -Variables $variables } | Should -Throw '*New Log Analytics workspaces*'
    }

    It 'accepts explicit reuse of a workspace in another resource group' {
        $variables.LOG_ANALYTICS_RESOURCE_GROUP = 'other-test-group'
        $variables.REUSE_LOG_ANALYTICS_WORKSPACE = 'true'
        $settings = Get-CollectorDeploymentSetting -Variables $variables
        $settings.LOG_ANALYTICS_RESOURCE_GROUP | Should -Be 'other-test-group'
    }

    It 'changes the revision suffix on a rerun so updated secrets are consumed' {
        $first = Get-CollectorDeploymentSetting -Variables $variables
        $variables.GITHUB_RUN_ATTEMPT = '2'
        $second = Get-CollectorDeploymentSetting -Variables $variables
        $second.REVISION_SUFFIX | Should -Not -Be $first.REVISION_SUFFIX
    }
}

Describe 'Azure deployment orchestration' {
    InModuleScope AzureDeployment {
        BeforeEach {
            $script:settings = @{
                AZURE_SUBSCRIPTION_ID = [guid]::NewGuid().ToString()
                AZURE_TENANT_ID = [guid]::NewGuid().ToString()
                AZURE_RESOURCE_GROUP = 'test-resource-group'
                APPINSIGHTS_NAME = 'test-insights'
                CONTAINER_APP_NAME = 'test-collector'
                CONTAINER_APP_ENVIRONMENT_NAME = 'test-environment'
                REUSE_CONTAINER_APP_ENVIRONMENT = 'false'
                LOG_ANALYTICS_WORKSPACE_NAME = 'test-logs'
                LOG_ANALYTICS_RESOURCE_GROUP = 'test-resource-group'
                REUSE_LOG_ANALYTICS_WORKSPACE = 'false'
                ALLOWED_IP_CIDRS = '["203.0.113.10/32"]'
                REVISION_SUFFIX = 'r-aaaaaaa-123456-1'
                GITHUB_SHA = 'a' * 40
                GITHUB_REPOSITORY = 'example/collector'
            }
            $script:originalConnectionString = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
            $script:originalLocation = $env:AZURE_LOCATION
            $script:insights = @{
                location = 'West Europe'
                connectionString = 'synthetic-runtime-value'
                disableLocalAuth = $false
                ingestionAccess = 'Enabled'
            }
            $script:resources = @()
            $script:preview = @{ status = 'Succeeded'; changes = @(); error = $null }
            $script:existingEnvironment = @{
                location = 'westeurope'
                internal = $false
                publicNetworkAccess = 'Enabled'
                profiles = @(@{ name = 'Consumption'; workloadProfileType = 'Consumption' })
            }
            Mock Get-CollectorDeploymentSetting { return $script:settings.Clone() }
            Mock Write-Host {}
            Mock Add-Content {}
            Mock Invoke-AzureJson {
                param($Arguments)
                switch ($Arguments[0..1] -join ' ') {
                    'account show' { return @{ id = $script:settings.AZURE_SUBSCRIPTION_ID; tenantId = $script:settings.AZURE_TENANT_ID } }
                    'provider show' { return @{ state = 'Registered'; locations = @('West Europe') } }
                    'resource show' {
                        if ($Arguments -contains 'Microsoft.Insights/components') { return $script:insights }
                        return $script:existingEnvironment
                    }
                    'resource list' { return $script:resources }
                    'resource wait' { return $null }
                    'deployment group' {
                        switch ($Arguments[2]) {
                            'validate' { return @{ status = 'Succeeded' } }
                            'what-if' { return $script:preview }
                            'create' {
                                return @{
                                    endpoint = @{ value = 'https://test-collector.example.invalid' }
                                    image = @{ value = 'test-image' }
                                }
                            }
                        }
                    }
                    default { throw 'Unexpected Azure command in test.' }
                }
            }
        }

        AfterEach {
            $env:APPLICATIONINSIGHTS_CONNECTION_STRING = $script:originalConnectionString
            $env:AZURE_LOCATION = $script:originalLocation
        }

        It 'runs validation and a secret-safe preview without creating resources in plan mode' {
            Invoke-CollectorDeployment -Operation plan
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter { $Arguments[0..2] -join ' ' -eq 'deployment group validate' }
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter {
                ($Arguments[0..2] -join ' ') -eq 'deployment group what-if' -and $Arguments -contains 'ResourceIdOnly' -and $Arguments -contains '--no-pretty-print'
            }
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'create' -or $Arguments -contains 'wait' }
        }

        It 'deploys incrementally then waits for the exact expected ready revision' {
            Invoke-CollectorDeployment -Operation deploy -ReviewedSha $script:settings.GITHUB_SHA -PrerequisitesConfirmed $true
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter {
                ($Arguments[0..2] -join ' ') -eq 'deployment group create' -and $Arguments -contains 'Incremental'
            }
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter {
                ($Arguments[0..1] -join ' ') -eq 'resource wait' -and
                ($Arguments -join ' ') -like '*latestReadyRevisionName*test-collector--r-aaaaaaa-123456-1*' -and
                $Arguments -contains '600'
            }
        }

        It 'supplies secrets only through the process environment and restores prior values' {
            $env:APPLICATIONINSIGHTS_CONNECTION_STRING = 'previous-runtime-value'
            $env:AZURE_LOCATION = 'previous-location'
            Mock Invoke-AzureJson { throw 'synthetic validation failure' } -ParameterFilter {
                ($Arguments[0..2] -join ' ') -eq 'deployment group validate' -and
                $env:APPLICATIONINSIGHTS_CONNECTION_STRING -eq 'synthetic-runtime-value' -and
                $env:AZURE_LOCATION -eq 'westeurope' -and
                $Arguments -notcontains 'synthetic-runtime-value'
            }
            { Invoke-CollectorDeployment -Operation plan } | Should -Throw 'synthetic validation failure'
            $env:APPLICATIONINSIGHTS_CONNECTION_STRING | Should -Be 'previous-runtime-value'
            $env:AZURE_LOCATION | Should -Be 'previous-location'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'create' }
        }

        It 'does not include the runtime connection string in a summary' {
            Invoke-CollectorDeployment -Operation plan
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                ($Object -join '') -like '*synthetic-runtime-value*' -and ($Object -join '') -notlike '::add-mask::*'
            }
            Should -Invoke Add-Content -Times 0 -Exactly -ParameterFilter { ($Value -join '') -like '*synthetic-runtime-value*' }
        }

        It 'rejects a mismatched Azure account before fetching configuration' {
            Mock Invoke-AzureJson { return @{ id = 'wrong-account'; tenantId = 'wrong-tenant' } } -ParameterFilter { $Arguments[0] -eq 'account' }
            { Invoke-CollectorDeployment } | Should -Throw '*does not match*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'resource' }
        }

        It 'does not register providers in plan mode' {
            Mock Invoke-AzureJson { return @{ state = 'NotRegistered'; locations = @() } } -ParameterFilter { $Arguments[0] -eq 'provider' }
            { Invoke-CollectorDeployment } | Should -Throw '*one-time Azure bootstrap*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'register' }
        }

        It 'rejects a missing connection string before any deployment command' {
            $script:insights.connectionString = ''
            { Invoke-CollectorDeployment } | Should -Throw '*APPLICATIONINSIGHTS_CONNECTION_STRING*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' }
        }

        It 'does not weaken existing Application Insights authentication' {
            $script:insights.disableLocalAuth = $true
            { Invoke-CollectorDeployment } | Should -Throw '*policy will not be changed*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' }
        }

        It 'does not bypass private Application Insights ingestion' {
            $script:insights.ingestionAccess = 'Disabled'
            { Invoke-CollectorDeployment } | Should -Throw '*policy will not be changed*'
        }

        It 'does not silently fall back to another region' {
            $script:insights.location = 'unsupported-region'
            { Invoke-CollectorDeployment } | Should -Throw '*No region fallback*'
        }

        It 'refuses to overwrite an unrelated existing container app' {
            $script:resources = @(@{ type = 'Microsoft.App/containerApps'; name = 'test-collector'; tags = $null })
            { Invoke-CollectorDeployment } | Should -Throw '*Refusing to overwrite*'
        }

        It 'allows repeat deployment of resources managed by this repository' {
            $script:resources = @(
                @{
                    type = 'Microsoft.App/containerApps'
                    name = 'test-collector'
                    tags = @{ 'managed-by' = 'github-actions'; repository = 'example/collector' }
                }
            )
            { Invoke-CollectorDeployment } | Should -Not -Throw
        }

        It 'rejects an incompatible reused environment: <Property>' -ForEach @(
            @{ Property = 'location'; Value = 'eastus' }
            @{ Property = 'internal'; Value = $true }
            @{ Property = 'publicNetworkAccess'; Value = 'Disabled' }
            @{ Property = 'profiles'; Value = @() }
        ) {
            $script:settings.REUSE_CONTAINER_APP_ENVIRONMENT = 'true'
            $script:existingEnvironment[$Property] = $Value
            { Invoke-CollectorDeployment } | Should -Throw '*selected environment must be public*'
        }

        It 'checks reused workspace read and listKeys access in <Operation> for <WorkspaceGroup>' -ForEach @(
            @{ Operation = 'plan'; WorkspaceGroup = 'test-resource-group' }
            @{ Operation = 'deploy'; WorkspaceGroup = 'test-resource-group' }
            @{ Operation = 'plan'; WorkspaceGroup = 'other-test-group' }
            @{ Operation = 'deploy'; WorkspaceGroup = 'other-test-group' }
        ) {
            $script:settings.REUSE_LOG_ANALYTICS_WORKSPACE = 'true'
            $script:settings.LOG_ANALYTICS_RESOURCE_GROUP = $WorkspaceGroup
            $workspaceUrl = "/subscriptions/$($script:settings.AZURE_SUBSCRIPTION_ID)/resourceGroups/$WorkspaceGroup/providers/Microsoft.OperationalInsights/workspaces/test-logs"
            Mock Invoke-AzureJson { return $true } -ParameterFilter { $Arguments[0] -eq 'rest' }

            $result = Invoke-CollectorDeployment -Operation $Operation
            $result | Should -BeNullOrEmpty

            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'rest' -and $Arguments -contains 'get' -and
                $Arguments -contains "${workspaceUrl}?api-version=2025-02-01" -and
                $Arguments -contains '--query' -and $Arguments -contains 'properties.customerId != `null`'
            }
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter {
                $Arguments[0] -eq 'rest' -and $Arguments -contains 'post' -and
                $Arguments -contains "$workspaceUrl/listKeys?api-version=2025-02-01" -and
                $Arguments -contains '--query' -and $Arguments -contains 'primarySharedKey != `null`'
            }
            Should -Invoke Invoke-AzureJson -Times 1 -Exactly -ParameterFilter { $Arguments[0..2] -join ' ' -eq 'deployment group validate' }
        }

        It 'stops <Operation> before validation when reused workspace <Method> access fails' -ForEach @(
            @{ Operation = 'plan'; Method = 'get' }
            @{ Operation = 'plan'; Method = 'post' }
            @{ Operation = 'deploy'; Method = 'get' }
            @{ Operation = 'deploy'; Method = 'post' }
        ) {
            $script:settings.REUSE_LOG_ANALYTICS_WORKSPACE = 'true'
            $script:settings.LOG_ANALYTICS_RESOURCE_GROUP = 'other-test-group'
            Mock Invoke-AzureJson { return $true } -ParameterFilter { $Arguments[0] -eq 'rest' }
            Mock Invoke-AzureJson { throw 'AuthorizationFailed: synthetic-sensitive-workspace-detail' } -ParameterFilter {
                $Arguments[0] -eq 'rest' -and $Arguments -contains $Method
            }

            $failure = { Invoke-CollectorDeployment -Operation $Operation } |
                Should -Throw '*Microsoft.OperationalInsights/workspaces/read*Microsoft.OperationalInsights/workspaces/listKeys/action*' -PassThru

            $failure.Exception.Message | Should -Not -BeLike '*synthetic-sensitive-workspace-detail*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'deployment' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { ($Object -join '') -like '*synthetic-sensitive-workspace-detail*' }
            Should -Invoke Add-Content -Times 0 -Exactly
        }

        It 'skips workspace access checks for environment reuse <ReuseEnvironment> and workspace reuse <ReuseWorkspace>' -ForEach @(
            @{ ReuseEnvironment = 'false'; ReuseWorkspace = 'false' }
            @{ ReuseEnvironment = 'true'; ReuseWorkspace = 'false' }
            @{ ReuseEnvironment = 'true'; ReuseWorkspace = 'true' }
        ) {
            $script:settings.REUSE_CONTAINER_APP_ENVIRONMENT = $ReuseEnvironment
            $script:settings.REUSE_LOG_ANALYTICS_WORKSPACE = $ReuseWorkspace

            Invoke-CollectorDeployment -Operation plan

            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'rest' }
        }

        It 'stops before apply if what-if fails' {
            $script:preview.status = 'Failed'
            { Invoke-CollectorDeployment -Operation deploy } | Should -Throw '*what-if did not succeed*'
            Should -Invoke Invoke-AzureJson -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'create' }
            $env:APPLICATIONINSIGHTS_CONNECTION_STRING | Should -Be $script:originalConnectionString
        }
    }
}

Describe 'Secret-safe Azure CLI output handling' {
    InModuleScope AzureDeployment {
        BeforeEach {
            Mock az { $global:LASTEXITCODE = 0; '[{"name":"first"},{"name":"second"}]' }
        }

        It 'returns JSON arrays as individual objects' {
            $resources = @(Invoke-AzureJson -Arguments @('resource', 'list'))
            $resources.Count | Should -Be 2
            $resources[0].name | Should -Be 'first'
        }

        It 'never includes raw CLI error output in an exception' {
            Mock az { $global:LASTEXITCODE = 1; 'synthetic-sensitive-error' }
            $failure = { Invoke-AzureJson -Arguments @('deployment', 'group', 'validate') } | Should -Throw '*Raw output is withheld*' -PassThru
            $failure.Exception.Message | Should -Not -BeLike '*synthetic-sensitive-error*'
        }

        It 'reports the command and exit code even when Azure CLI produces no output' {
            Mock az { $global:LASTEXITCODE = 1 }
            { Invoke-AzureJson -Arguments @('deployment', 'group', 'validate') } |
                Should -Throw '*deployment group validate failed (exit 1)*'
        }

        It 'identifies the failed deployment subcommand and nested Azure errors' {
            Mock az {
                $global:LASTEXITCODE = 1
                'ERROR: {"error":{"code":"InvalidTemplateDeployment","message":"Validation failed.","details":[{"code":"LinkedAuthorizationFailed","message":"Missing permission to read workspace shared keys."}]}}'
            }
            $failure = { Invoke-AzureJson -Arguments @('deployment', 'group', 'validate') } | Should -Throw '*deployment group validate failed*' -PassThru
            $failure.Exception.Message | Should -BeLike '*InvalidTemplateDeployment*LinkedAuthorizationFailed*Missing permission*'
        }

        It 'recognizes standard Azure CLI error formatting' {
            Mock az {
                $global:LASTEXITCODE = 1
                'ERROR: (InvalidTemplate) The template contains an invalid resource reference.'
            }
            { Invoke-AzureJson -Arguments @('deployment', 'group', 'what-if') } |
                Should -Throw '*deployment group what-if failed*InvalidTemplate*invalid resource reference*'
        }

        It 'redacts the runtime connection string from recognized diagnostics' {
            $previousValue = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
            try {
                $env:APPLICATIONINSIGHTS_CONNECTION_STRING = 'synthetic-private-runtime-value'
                Mock az {
                    $global:LASTEXITCODE = 1
                    'ERROR: (InvalidTemplate) Unexpected value synthetic-private-runtime-value in the template.'
                }
                $failure = { Invoke-AzureJson -Arguments @('deployment', 'group', 'validate') } | Should -Throw '*InvalidTemplate*' -PassThru
                $failure.Exception.Message | Should -Not -BeLike '*synthetic-private-runtime-value*'
                $failure.Exception.Message | Should -BeLike '*<redacted>*'
            }
            finally {
                if ($null -eq $previousValue) { Remove-Item Env:APPLICATIONINSIGHTS_CONNECTION_STRING -ErrorAction SilentlyContinue }
                else { $env:APPLICATIONINSIGHTS_CONNECTION_STRING = $previousValue }
            }
        }

        It 'redacts credential fields and ignores unrelated JSON response fields' {
            Mock az {
                $global:LASTEXITCODE = 1
                'ERROR: {"code":"InvalidTemplate","message":"Bad sharedKey=synthetic-key; password=synthetic-password; Bearer synthetic-token","request":{"value":"synthetic-request-secret"}}'
            }
            $failure = { Invoke-AzureJson -Arguments @('deployment', 'group', 'validate') } | Should -Throw '*InvalidTemplate*' -PassThru
            $failure.Exception.Message | Should -Not -Match 'synthetic-(key|password|token|request-secret)'
        }

        It 'never includes malformed JSON output in an exception' {
            Mock az { $global:LASTEXITCODE = 0; 'synthetic-sensitive-output' }
            $failure = { Invoke-AzureJson -Arguments @('resource', 'show') } | Should -Throw '*unexpected output*' -PassThru
            $failure.Exception.Message | Should -Not -BeLike '*synthetic-sensitive-output*'
        }
    }
}