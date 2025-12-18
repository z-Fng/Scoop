function Get-Dependency {
    <#
    .SYNOPSIS
        Get app's dependencies (with apps attached at the end).
    .PARAMETER AppName
        App's name
    .PARAMETER Architecture
        App's architecture
    .PARAMETER Resolved
        List of resolved dependencies (internal use)
    .PARAMETER Unresolved
        List of unresolved dependencies (internal use)
    .OUTPUTS
        [Object[]]
        List of app's dependencies
    .NOTES
        When pipeline input is used, the output will have duplicate items, and should be filtered by 'Select-Object -Unique'.
        Algorithm: http://www.electricmonk.nl/docs/dependency_resolving_algorithm/dependency_resolving_algorithm.html
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [PSObject]
        $AppName,
        [Parameter(Mandatory = $true, Position = 1)]
        [String]
        $Architecture,
        [String[]]
        $Resolved = @(),
        [String[]]
        $Unresolved = @()
    )
    process {
        $AppName, $manifest, $bucket, $url = Get-Manifest $AppName
        $Unresolved += $AppName

        if (!$manifest) {
            if (((Get-LocalBucket) -notcontains $bucket) -and $bucket) {
                warn "Bucket '$bucket' not added. Add it with $(if($bucket -in (known_buckets)) { "'scoop bucket add $bucket' or " })'scoop bucket add $bucket <repo>'."
            }
            abort "Couldn't find manifest for '$AppName'$(if($bucket) { " from '$bucket' bucket" } elseif($url) { " at '$url'" })."
        }

        $deps = @(Get-InstallationHelper $manifest $Architecture) + @($manifest.depends) | Select-Object -Unique

        foreach ($dep in $deps) {
            if ($Resolved -notcontains $dep) {
                if ($Unresolved -contains $dep) {
                    abort "Circular dependency detected: '$AppName' -> '$dep'."
                }
                $Resolved, $Unresolved = Get-Dependency $dep $Architecture -Resolved $Resolved -Unresolved $Unresolved
            }
        }

        $Unresolved = $Unresolved -ne $AppName
        if ($bucket) {
            $Resolved += "$bucket/$AppName"
        } else {
            if ($url) {
                $Resolved += $url
            } else {
                $Resolved += $AppName
            }
        }
        if ($Unresolved.Length -eq 0) {
            return $Resolved
        } else {
            return $Resolved, $Unresolved
        }
    }
}

function Get-InstallationHelper {
    <#
    .SYNOPSIS
        Get helpers that used in installation
    .PARAMETER Manifest
        App's manifest
    .PARAMETER Architecture
        Architecture of the app
    .PARAMETER All
        If true, return all helpers, otherwise return only helpers that are not already installed
    .OUTPUTS
        [Object[]]
        List of helpers
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [PSObject]
        $Manifest,
        [Parameter(Mandatory = $true, Position = 1)]
        [String]
        $Architecture,
        [Switch]
        $All
    )
    begin {
        $helper = @()
    }
    process {
        $url = arch_specific 'url' $Manifest $Architecture
        $pre_install = arch_specific 'pre_install' $Manifest $Architecture
        $installer = arch_specific 'installer' $Manifest $Architecture
        $post_install = arch_specific 'post_install' $Manifest $Architecture
        $script = $pre_install + $installer.script + $post_install
        if (((Test-7zipRequirement -Uri $url) -or ($script -like '*Expand-7zipArchive *')) -and !(get_config USE_EXTERNAL_7ZIP)) {
            $helper += '7zip'
        }
        if (((Test-LessmsiRequirement -Uri $url) -or ($script -like '*Expand-MsiArchive *')) -and (get_config USE_LESSMSI)) {
            $helper += 'lessmsi'
        }
        if ($Manifest.innosetup -or ($script -like '*Expand-InnoArchive *')) {
            $helper += 'innounp'
        }
        if ($script -like '*Expand-DarkArchive *') {
            $helper += 'dark'
        }
        if (!$All) {
            '7zip', 'lessmsi', 'innounp', 'dark' | ForEach-Object {
                if (Test-HelperInstalled -Helper $_) {
                    $helper = $helper -ne $_
                }
            }
        }
    }
    end {
        return $helper
    }
}

function Test-7zipRequirement {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [String[]]
        $Uri
    )
    return ($Uri | Where-Object {
            $_ -match '\.(001|7z|bz(ip)?2?|gz|img|iso|lzma|lzh|nupkg|rar|tar|t[abgpx]z2?|t?zst|xz)(\.[^\d.]+)?$'
        }).Count -gt 0
}

function Test-LessmsiRequirement {
    [CmdletBinding()]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [String[]]
        $Uri
    )
    return ($Uri | Where-Object { $_ -match '\.msi$' }).Count -gt 0
}

function Get-OutdatedHelper {
    <#
    .SYNOPSIS
        Get outdated installation helpers
    .DESCRIPTION
        Walks the installation helpers required by the given apps or manifests, including the helpers
        required by those helpers, and returns the ones that need an update. Helpers are sorted
        so that each helper is updated after the helpers it requires.
    .PARAMETER App
        Installed app name. Its manifest is resolved from the install information.
    .PARAMETER Global
        Whether the app given by -App is installed globally
    .PARAMETER Manifest
        Manifest of an app that is not installed yet. Use together with -Architecture.
    .PARAMETER Architecture
        Architecture used to inspect the given manifest
    .PARAMETER Force
        Keep the force flag for helpers that are already part of the update list, so that
        up-to-date helpers from that list are returned as well
    .PARAMETER Quiet
        Suppress messages about skipped helpers
    .OUTPUTS
        [Object[]]
        A list of concrete outdated helper apps, each represented as a PSCustomObject
        with 'App', 'Global', 'Status', 'Reason' and 'Force' properties
    .NOTES
        helper  | concrete helper name
        7zip    | 7zip
        lessmsi | lessmsi
        innounp | innounp-unicode/innounp
        dark    | dark/wixtoolset
    #>
    [CmdletBinding(DefaultParameterSetName = 'App')]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'App')]
        [String]
        $App,
        [Parameter(ValueFromPipelineByPropertyName, ParameterSetName = 'App')]
        [Switch]
        $Global,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'Manifest')]
        [PSObject]
        $Manifest,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'Manifest')]
        [String]
        $Architecture,
        [Switch]
        $Force,
        [Switch]
        $Quiet
    )

    begin {
        # Concrete helper apps seen so far, keyed by app name (ordered for stable output)
        $helpers = [ordered]@{}
        $seen = @{}
        # Map of helper app name to the helper apps it requires while installing
        $requires = @{}
        # Apps that are already part of the update list, keyed by 'app|global'
        $targets = @{}
        $seeds = [System.Collections.Generic.List[object]]::new()
        $pending = [System.Collections.Generic.Queue[object]]::new()
    }

    process {
        # Collect all inputs first: a helper is only known to be part of the update
        # list once every piped app has been seen.
        if ($PSCmdlet.ParameterSetName -eq 'App') {
            $targets[('{0}|{1}' -f $App, [bool]$Global)] = $true
            $seeds.Add([PSCustomObject]@{ Kind = 'App'; App = $App; Global = [bool]$Global })
        } else {
            $seeds.Add([PSCustomObject]@{ Kind = 'Manifest'; Manifest = $Manifest; Architecture = $Architecture })
        }
    }

    end {
        foreach ($seed in $seeds) {
            if ($seed.Kind -eq 'App') {
                $version = Select-CurrentVersion -AppName $seed.App -Global:$seed.Global
                $install = install_info $seed.App $version $seed.Global
                $manifest = manifest $seed.App $install.bucket $install.url
                $architecture = Format-ArchitectureString -Architecture $install.architecture
            } else {
                $manifest = $seed.Manifest
                $architecture = $seed.Architecture
            }

            if (-not $manifest) {
                continue
            }

            $pending.Enqueue([PSCustomObject]@{
                    Manifest     = $manifest
                    Architecture = $architecture
                    App          = $null
                })

            while ($pending.Count -gt 0) {
                $item = $pending.Dequeue()

                foreach ($helper in (Get-InstallationHelper -Manifest $item.Manifest -Architecture $item.Architecture -All)) {
                    $app = Get-InstalledHelperApp -Helper $helper

                    if (-not $app) {
                        continue
                    }

                    if ($item.App) {
                        if (-not $requires.ContainsKey($item.App)) {
                            $requires[$item.App] = @()
                        }
                        if ($requires[$item.App] -notcontains $app) {
                            $requires[$item.App] += $app
                        }
                    }

                    if ($seen.ContainsKey($app)) {
                        continue
                    }
                    $seen[$app] = $true

                    $isGlobal = installed $app $true
                    $status = app_status $app $isGlobal
                    # Only helpers that are already part of the update list keep the force flag
                    $forceHelper = $Force -and $targets.ContainsKey(('{0}|{1}' -f $app, $isGlobal))

                    if (-not ($status.installed -and ($status.outdated -or $forceHelper))) {
                        continue
                    }

                    $reason = if ($forceHelper) { 'forced' } else { 'outdated' }

                    if ($status.hold) {
                        $reason = 'held'
                    } elseif ($isGlobal -and -not (is_admin)) {
                        $reason = 'permission'
                    }

                    $helpers[$app] = [PSCustomObject]@{
                        App    = $app
                        Global = $isGlobal
                        Status = $status
                        Reason = $reason
                        Force  = $forceHelper
                    }

                    if ($reason -in @('held', 'permission')) {
                        continue
                    }

                    # Helpers may require other helpers themselves, e.g. the MSI-based '7zip' needs 'lessmsi'
                    $version = Select-CurrentVersion -AppName $app -Global:$isGlobal
                    $install = install_info $app $version $isGlobal
                    $helperManifest = manifest $app $install.bucket $install.url

                    if ($helperManifest) {
                        $pending.Enqueue([PSCustomObject]@{
                                Manifest     = $helperManifest
                                Architecture = Format-ArchitectureString -Architecture $install.architecture
                                App          = $app
                            })
                    }
                }
            }
        }

        # Report helpers that cannot be updated before returning the update list
        foreach ($helper in @($helpers.Values | Where-Object { $_.Reason -eq 'held' })) {
            if (!$Quiet) {
                warn "Skipping update of '$($helper.App)' because it is held at version $($helper.Status.version)."
                warn ("Outdated extraction tool may cause decompression errors. Please run 'scoop unhold $($helper.App){0}' to unhold it." -f ('', ' -g')[$helper.Global])
            }
        }
        foreach ($helper in @($helpers.Values | Where-Object { $_.Reason -eq 'permission' })) {
            if (!$Quiet) {
                warn "Skipping update of '$($helper.App)' because it is globally installed and requires admin rights to update."
                warn "Outdated extraction tool may cause decompression errors. Please run 'scoop update $($helper.App) -g' to update it."
            }
        }

        $outdated = @($helpers.Values | Where-Object { $_.Reason -in @('outdated', 'forced') })
        return Sort-OutdatedHelper -Helpers $outdated -Requires $requires -Quiet:$Quiet
    }
}

function Sort-OutdatedHelper {
    <#
    .SYNOPSIS
        Sort helpers so that each helper is updated after the helpers it requires.
    .PARAMETER Helpers
        Helper objects to sort, each with an 'App' property
    .PARAMETER Requires
        Map of helper app name to the helper apps it requires
    .PARAMETER Quiet
        Suppress the warning about circular helper dependencies
    .OUTPUTS
        [Object[]]
        The same helper objects in dependency order
    .NOTES
        The sort is best-effort. When helpers require each other in a cycle, the helpers
        involved keep their discovery order and a warning is printed.
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Object[]]
        $Helpers,
        [Parameter(Mandatory)]
        [AllowNull()]
        [HashTable]
        $Requires,
        [Switch]
        $Quiet
    )

    if ($Helpers.Count -le 1) {
        return $Helpers
    }

    $names = @($Helpers | ForEach-Object { $_.App })
    $missing = @{}
    foreach ($name in $names) {
        $missing[$name] = 0
        foreach ($required in @($Requires[$name])) {
            if ($required -and $required -ne $name -and $names -contains $required) {
                $missing[$name]++
            }
        }
    }

    $sorted = [System.Collections.Generic.List[object]]::new()
    $ready = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $names) {
        if ($missing[$name] -eq 0) {
            $ready.Enqueue($name)
        }
    }

    while ($ready.Count -gt 0) {
        $name = $ready.Dequeue()
        $sorted.Add(($Helpers | Where-Object { $_.App -eq $name } | Select-Object -First 1))
        foreach ($RequiredBy in $names) {
            if ($RequiredBy -ne $name -and @($Requires[$RequiredBy]) -contains $name) {
                $missing[$RequiredBy]--
                if ($missing[$RequiredBy] -eq 0) {
                    $ready.Enqueue($RequiredBy)
                }
            }
        }
    }

    if ($sorted.Count -lt $names.Count) {
        $unordered = @($names | Where-Object { $missing[$_] -gt 0 })
        if (!$Quiet) {
            warn ("Circular dependency between extraction tools detected: {0}. Updating them in discovery order; some updates may fail." -f ($unordered -join ', '))
        }
        foreach ($name in $unordered) {
            $sorted.Add(($Helpers | Where-Object { $_.App -eq $name } | Select-Object -First 1))
        }
    }

    return $sorted.ToArray()
}
