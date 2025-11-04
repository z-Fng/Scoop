Describe 'Static Code Analysis' {
    BeforeAll {
        . "$PSScriptRoot\Scoop-StaticAnalysisLib.ps1"
    }

    Context 'Dot-sourcing dependency check' {
        BeforeDiscovery {
            $TestCases = @(
                @{
                    LibFolder    = "$PSScriptRoot\..\lib"
                    ScriptFolder = "$PSScriptRoot\..\libexec"
                    Entry        = "$PSScriptRoot\..\bin\scoop.ps1"
                }
                @{
                    LibFolder    = "$PSScriptRoot\..\lib"
                    ScriptFolder = "$PSScriptRoot\..\bin"
                    Entry        = ''
                }
            )
        }

        It 'For <_.ScriptFolder> Should pass' -TestCases $TestCases {
            $FlagMissingDep = $false

            $Libs = Get-ChildItem -Path $LibFolder | Select-Object -ExpandProperty FullName
            $Scripts = Get-ChildItem -Path $ScriptFolder | Select-Object -ExpandProperty FullName

            $AllDeps = $Scripts | Get-DotsourcingDependency -Libs $Libs
            $PreImportedDeps = if ([string]::IsNullOrWhiteSpace($Entry)) { @() } else { Get-ImportedDependency -Path $Entry }

            $Scripts | ForEach-Object {
                $Path = $_

                $Deps = $AllDeps[$Path]
                if (-not $Deps) {
                    $FlagMissingDep = $true
                    Write-Host "Error parsing dot-sourcing dependency for $Path."
                }

                $ImportedDeps = Get-ImportedDependency -Path $Path

                $Deps.Keys | Where-Object { ($_ -notin $ImportedDeps) -and ($_ -notin $PreImportedDeps) } | ForEach-Object {
                    $FlagMissingDep = $true

                    Write-Host "Missing dot-sourcing dependency in $Path : $_"
                    $Deps[$_] | ForEach-Object {
                        Write-Host "`tFunction $($_.Name) called at $($_.File):$($_.Line)"
                    }
                }
            }

            $FlagMissingDep | Should -BeFalse
        }
    }
}
