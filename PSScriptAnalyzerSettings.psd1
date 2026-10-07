# Invoke-ScriptAnalyzer -Path install.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # An installer run as `irm | iex` talks to the person at the console;
        # Write-Output would mix its messages into the pipeline.
        'PSAvoidUsingWriteHost',
        # test/smoke-install.ps1 runs install.ps1 exactly as `irm | iex` does.
        'PSAvoidUsingInvokeExpression'
    )
}
