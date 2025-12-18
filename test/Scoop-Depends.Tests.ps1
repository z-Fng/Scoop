BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\depends.ps1"
    . "$PSScriptRoot\..\lib\buckets.ps1"
    . "$PSScriptRoot\..\lib\install.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\versions.ps1"
}

Describe 'Package Dependencies' -Tag 'Scoop' {
    Context 'Requirement function' {
        It 'Test 7zip requirement' {
            Test-7zipRequirement -Uri 'test.xz' | Should-BeTrue
            Test-7zipRequirement -Uri 'test.bin' | Should-BeFalse
            Test-7zipRequirement -Uri @('test.xz', 'test.bin') | Should-BeTrue
        }
        It 'Test lessmsi requirement' {
            Mock get_config { $true }
            Test-LessmsiRequirement -Uri 'test.msi' | Should-BeTrue
            Test-LessmsiRequirement -Uri 'test.bin' | Should-BeFalse
            Test-LessmsiRequirement -Uri @('test.msi', 'test.bin') | Should-BeTrue
        }
        It 'Allow $Uri be $null' {
            Test-7zipRequirement -Uri $null | Should-BeFalse
            Test-LessmsiRequirement -Uri $null | Should-BeFalse
        }
    }

    Context 'InstallationHelper function' {
        BeforeAll {
            $working_dir = setup_working 'format/formatted'
            $manifest1 = parse_json (Join-Path $working_dir '3-array-with-single-and-multi.json')
            $manifest2 = parse_json (Join-Path $working_dir '4-script-block.json')
            Mock Test-HelperInstalled { $false }
        }
        It 'Get helpers from URL' {
            Mock get_config { $true }
            Get-InstallationHelper -Manifest $manifest1 -Architecture '32bit' | Should-BeCollection @('lessmsi')
        }
        It 'Get helpers from script' {
            Mock get_config { $false }
            Get-InstallationHelper -Manifest $manifest2 -Architecture '32bit' | Should-BeCollection @('7zip')
        }
        It 'Helpers reflect config changes' {
            Mock get_config { $false } -ParameterFilter { $name -eq 'USE_LESSMSI' }
            Mock get_config { $true } -ParameterFilter { $name -eq 'USE_EXTERNAL_7ZIP' }
            Get-InstallationHelper -Manifest $manifest1 -Architecture '32bit' | Should-BeNull
            Get-InstallationHelper -Manifest $manifest2 -Architecture '32bit' | Should-BeNull
        }
        It 'Not return installed helpers' {
            Mock get_config { $true } -ParameterFilter { $name -eq 'USE_LESSMSI' }
            Mock get_config { $false } -ParameterFilter { $name -eq 'USE_EXTERNAL_7ZIP' }
            Mock Test-HelperInstalled { $true }-ParameterFilter { $Helper -eq '7zip' }
            Mock Test-HelperInstalled { $false }-ParameterFilter { $Helper -eq 'Lessmsi' }
            Get-InstallationHelper -Manifest $manifest1 -Architecture '32bit' | Should-BeCollection @('lessmsi')
            Get-InstallationHelper -Manifest $manifest2 -Architecture '32bit' | Should-BeNull
            Mock Test-HelperInstalled { $false }-ParameterFilter { $Helper -eq '7zip' }
            Mock Test-HelperInstalled { $true }-ParameterFilter { $Helper -eq 'Lessmsi' }
            Get-InstallationHelper -Manifest $manifest1 -Architecture '32bit' | Should-BeNull
            Get-InstallationHelper -Manifest $manifest2 -Architecture '32bit' | Should-BeCollection @('7zip')
        }
    }

    Context 'Outdated helpers' {
        BeforeEach {
            Mock Get-InstallationHelper { @() }
            Mock Get-InstalledHelperApp { $null }
            Mock installed { $false }
            Mock is_admin { $false }
            Mock app_status { [PSCustomObject]@{ installed = $true; outdated = $true; hold = $false; version = '1.0'; latest_version = '2.0' } }
            Mock Select-CurrentVersion { '1.0' }
            Mock install_info { [PSCustomObject]@{ bucket = 'main'; url = $null; architecture = '64bit' } }
            Mock manifest { $null }
            Mock warn { }
        }

        It 'Returns outdated helpers required by the manifest' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper)

            $result.App | Should-BeCollection @('lessmsi')
            $result[0].Global | Should-BeFalse
            $result[0].Status.version | Should-Be '1.0'
        }

        It 'Resolves the manifest from an installed app name and global flag' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'resolved-manifest' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock manifest { @{ name = 'resolved-manifest' } } -ParameterFilter { $app -eq 'app' }

            $result = @([PSCustomObject]@{ App = 'app'; Global = $false } | Get-OutdatedHelper)

            $result.App | Should-BeCollection @('lessmsi')
            Should-Invoke -CommandName Select-CurrentVersion -Times 1 -ParameterFilter { $AppName -eq 'app' -and $Global -eq $false }
            Should-Invoke -CommandName install_info -Times 1 -ParameterFilter { $app -eq 'app' -and $version -eq '1.0' -and $global -eq $false }
        }

        It 'Walks helpers required by helpers' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -eq 'lessmsi' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }
            Mock manifest { @{ name = 'lessmsi' } } -ParameterFilter { $app -eq 'lessmsi' }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper)

            # 'lessmsi' requires '7zip', so '7zip' has to be updated first
            $result.App | Should-BeCollection @('7zip', 'lessmsi')
        }

        It 'Keeps discovery order and warns on a circular helper dependency' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -eq 'lessmsi' }
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq '7zip' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }
            Mock manifest { @{ name = 'lessmsi' } } -ParameterFilter { $app -eq 'lessmsi' }
            Mock manifest { @{ name = '7zip' } } -ParameterFilter { $app -eq '7zip' }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper)

            $result.App | Should-BeCollection @('lessmsi', '7zip')
            Should-Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -like '*Circular dependency between extraction tools*' }
        }

        It 'Does not return a helper twice when several manifests need it' {
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -in @('app1', 'app2') }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }

            $result = @(@(
                    [PSCustomObject]@{ Manifest = @{ name = 'app1' }; Architecture = '64bit' }
                    [PSCustomObject]@{ Manifest = @{ name = 'app2' }; Architecture = '64bit' }
                ) | Get-OutdatedHelper)

            $result.App | Should-BeCollection @('7zip')
        }

        It 'Does not force up-to-date helpers that are only discovered from other apps' {
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }
            Mock manifest { @{ name = 'app' } } -ParameterFilter { $app -eq 'app' }
            Mock app_status { [PSCustomObject]@{ installed = $true; outdated = $false; hold = $false; version = '2.0'; latest_version = '2.0' } }

            $outdated = @([PSCustomObject]@{ App = 'app'; Global = $false })

            @($outdated | Get-OutdatedHelper -Force) | Should-BeCollection -Count 0
        }

        It 'Keeps the force flag for an up-to-date helper that is already in the update list' {
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }
            Mock manifest { @{ name = 'app' } } -ParameterFilter { $app -eq 'app' }
            Mock app_status { [PSCustomObject]@{ installed = $true; outdated = $false; hold = $false; version = '2.0'; latest_version = '2.0' } }

            $outdated = @(
                [PSCustomObject]@{ App = 'app'; Global = $false }
                [PSCustomObject]@{ App = '7zip'; Global = $false }
            )
            $result = @($outdated | Get-OutdatedHelper -Force)

            $result.App | Should-BeCollection @('7zip')
            $result[0].Force | Should-BeTrue
        }

        It 'Does not force helpers that are only outdated' {
            Mock Get-InstallationHelper { @('7zip') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { '7zip' } -ParameterFilter { $Helper -eq '7zip' }
            Mock manifest { @{ name = 'app' } } -ParameterFilter { $app -eq 'app' }

            $outdated = @([PSCustomObject]@{ App = 'app'; Global = $false })
            $result = @($outdated | Get-OutdatedHelper -Force)

            $result.App | Should-BeCollection @('7zip')
            $result[0].Force | Should-BeFalse
        }

        It 'Skips held helpers and warns' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock app_status { [PSCustomObject]@{ installed = $true; outdated = $true; hold = $true; version = '1.0'; latest_version = '2.0' } }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper)

            $result | Should-BeCollection -Count 0
            Should-Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -like '*because it is held*' }
        }

        It 'Skips globally installed helpers without admin rights and warns' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock installed { $true } -ParameterFilter { $app -eq 'lessmsi' -and $global -eq $true }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper)

            $result | Should-BeCollection -Count 0
            Should-Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -like '*requires admin rights*' }
        }

        It 'Does not warn about skipped helpers with -Quiet' {
            Mock Get-InstallationHelper { @('lessmsi') } -ParameterFilter { $Manifest.name -eq 'app' }
            Mock Get-InstalledHelperApp { 'lessmsi' } -ParameterFilter { $Helper -eq 'lessmsi' }
            Mock app_status { [PSCustomObject]@{ installed = $true; outdated = $true; hold = $true; version = '1.0'; latest_version = '2.0' } }

            $result = @([PSCustomObject]@{ Manifest = @{ name = 'app' }; Architecture = '64bit' } | Get-OutdatedHelper -Quiet)

            $result | Should-BeCollection -Count 0
            Should-Invoke -CommandName warn -Times 0
        }
    }

    Context 'Dependencies resolution' {
        BeforeAll {
            Mock Test-HelperInstalled { $false }
            Mock get_config { $true } -ParameterFilter { $name -eq 'USE_LESSMSI' }
            Mock get_config { $false } -ParameterFilter { $name -eq 'USE_EXTERNAL_7ZIP' }
            Mock Get-Manifest { 'lessmsi', @{}, $null, $null } -ParameterFilter { $app -eq 'lessmsi' }
            Mock Get-Manifest { '7zip', @{ url = 'test.msi' }, $null, $null } -ParameterFilter { $app -eq '7zip' }
            Mock Get-Manifest { 'innounp', @{}, $null, $null } -ParameterFilter { $app -eq 'innounp' }
        }

        It 'Resolve install dependencies' {
            Mock Get-Manifest { 'test', @{ url = 'test.7z' }, $null, $null }
            $deps = Get-Dependency -AppName 'test' -Architecture '32bit'
            $deps | Should-BeCollection -Count 3
            $deps | Should-ContainCollection @('lessmsi', '7zip', 'test')
            Mock Get-Manifest { 'test', @{ innosetup = $true }, $null, $null }
            $deps = Get-Dependency -AppName 'test' -Architecture '32bit'
            $deps | Should-BeCollection -Count 2
            $deps | Should-ContainCollection @('innounp', 'test')
        }
        It 'Resolve script dependencies' {
            Mock Get-Manifest { 'test', @{ pre_install = 'Expand-7zipArchive ' }, $null, $null }
            $deps = Get-Dependency -AppName 'test' -Architecture '32bit'
            $deps | Should-BeCollection -Count 3
            $deps | Should-ContainCollection @('lessmsi', '7zip', 'test')
        }
        It 'Resolve runtime dependencies' {
            Mock Get-Manifest { 'depends', @{}, $null, $null } -ParameterFilter { $app -eq 'depends' }
            Mock Get-Manifest { 'test', @{ depends = 'depends' }, $null, $null }
            $deps = Get-Dependency -AppName 'test' -Architecture '32bit'
            $deps | Should-BeCollection -Count 2
            $deps | Should-ContainCollection @('depends', 'test')
        }
        It 'Keep bucket name of app' {
            Mock Get-Manifest { 'depends', @{}, 'anotherbucket', $null } -ParameterFilter { $app -eq 'anotherbucket/depends' }
            Mock Get-Manifest { 'test', @{ depends = 'anotherbucket/depends' }, 'bucket', $null }
            $deps = Get-Dependency -AppName 'bucket/test' -Architecture '32bit'
            $deps | Should-BeCollection -Count 2
            $deps | Should-ContainCollection @('anotherbucket/depends', 'bucket/test')
        }
    }
}
