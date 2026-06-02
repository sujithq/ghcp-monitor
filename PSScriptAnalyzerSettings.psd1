# PSScriptAnalyzer settings for ai-monitor
# Run: Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1
@{
    Severity = @('Error', 'Warning')

    # Use the standard, well-tested rule set.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # The script intentionally writes status output to the host.
        'PSAvoidUsingWriteHost',

        # Start/Stop helpers are private functions in a self-contained script,
        # not exported cmdlets, so ShouldProcess plumbing is unnecessary.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
    }
}
