#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'BuildHelpers'; ModuleVersion = '2.0.1' }
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.2.0' }
#Requires -Modules @{ ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.17.1' }
param(
    [String] $TestPath = (Convert-Path "$PSScriptRoot\..\tests\integration-test")
)

Import-Module "$PSScriptRoot\..\lib\Scoop.psm1"

$pesterConfig = New-PesterConfiguration -Hashtable @{
    Run    = @{
        Path     = $TestPath
        PassThru = $true
    }
    Output = @{
        Verbosity = 'Detailed'
    }
}
$excludes = @()

if ($IsLinux -or $IsMacOS) {
    Write-Warning 'Skipping Windows-only tests on Linux/macOS'
    $excludes += 'Windows'
}

if ($env:CI -eq $true) {
    # Display CI environment variables
    $buildVariables = (Get-ChildItem -Path 'Env:').Where({ $_.Name -match '^(?:BH|CI(?:_|$)|APPVEYOR|GITHUB_|RUNNER_|SCOOP_)' })
    $details = $buildVariables |
        Where-Object -FilterScript { $_.Name -notmatch 'EMAIL' } |
        Sort-Object -Property 'Name' |
        Format-Table -AutoSize -Property 'Name', 'Value' |
        Out-String
    Write-Host 'CI variables:'
    Write-Host $details -ForegroundColor DarkGray

    Install-Scoop
}

if ($excludes.Length -gt 0) {
    $pesterConfig.Filter.ExcludeTag = $excludes
}

if ($env:BHBuildSystem -eq 'AppVeyor') {
    # AppVeyor
    $resultsXml = "$PSScriptRoot\TestResults.xml"
    $pesterConfig.TestResult.Enabled = $true
    $pesterConfig.TestResult.OutputPath = $resultsXml
    $result = Invoke-Pester -Configuration $pesterConfig
    Add-TestResultToAppveyor -TestFile $resultsXml
} else {
    # GitHub Actions / Local
    $result = Invoke-Pester -Configuration $pesterConfig
}

exit $result.FailedCount
