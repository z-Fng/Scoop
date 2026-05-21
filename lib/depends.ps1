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
        ALgorithm: http://www.electricmonk.nl/docs/dependency_resolving_algorithm/dependency_resolving_algorithm.html
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
    .PARAMETER IncludeInstalled
        Include helpers that are already installed. By default, only missing helpers are returned.
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
        $IncludeInstalled
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
        if (!$IncludeInstalled) {
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
    .PARAMETER Manifest
        App's Manifest
    .PARAMETER Architecture
        Architecture of the app
    .OUTPUTS
        [Object[]]
        A list of concrete outdated helper apps, each represented as a PSCustomObject with 'App' and 'Global' properties
    .NOTES
        Concrete helper app priority is defined by Get-HelperCandidate.
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [PSObject]
        $Manifest,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [String]
        $Architecture
    )

    begin {
        $helpers = @()
    }

    process {
        $helpers += Get-InstallationHelper -Manifest $Manifest -Architecture $Architecture -IncludeInstalled | Where-Object {
            (Test-HelperInstalled -Helper $_) -and ($helpers -notcontains $_)
        }
    }

    end {
        $outdated = @()

        foreach ($helper in $helpers) {
            $app = Get-InstalledHelperApp -Helper $helper

            if (-not $app) {
                continue
            }

            $global = installed $app $true
            $status = app_status $app $global

            if (-not ($status.installed -and $status.outdated)) {
                continue
            }

            warn ("Outdated extraction tool '$app' detected: $($status.version) -> $($status.latest_version){0}." -f ('', ' (global)')[$global])

            # Filter out outdated helpers that are held
            if ($status.hold) {
                warn "Skipping update of '$app' because it is held at version $($status.version)."
                warn ("Outdated extraction tool may cause decompression errors. Please run 'scoop unhold $app{0}' to unhold it." -f ('', ' -g')[$global])
                continue
            }

            # Filter out outdated helpers that are blocked by permission issues
            if ((-not (is_admin)) -and $global) {
                warn "Skipping update of '$app' because it is globally installed and requires admin rights to update."
                warn "Outdated extraction tool may cause decompression errors. Please run 'scoop update $app -g' to update it."
                continue
            }

            $outdated += [PSCustomObject]@{
                App    = $app
                Global = $global
            }
        }

        return , $outdated
    }
}
