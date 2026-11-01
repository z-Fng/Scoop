# Usage: scoop versions <app> [options]
# Summary: List historical versions of an app
# Help: Lists versions of <app> recorded in the bucket's Git history and/or
# the SQLite cache.
#
# <app> may be 'app' or 'bucket/app'. 'app@version' is not supported.
#
# Options:
#   -s, --source <all|git_history|sqlite_cache>  Where to read versions from (default: all)
#
# Notes:
#   - Versions follow the source order: Git history newest first, then SQLite
#     cache order.
#   - SQLite has no timestamp; its order is cache insertion order, newest first.
#   - 'Updated' is the local committer time from Git.
#   - Sources disabled by 'use_git_history' or 'use_sqlite_cache' are skipped.
#   - SQLite history only contains versions captured since 'use_sqlite_cache'
#     was enabled. Git history is usually more complete.
#   - No results is not an error; a warning is shown and the command exits 0.
#   - Versions that only autoupdate can generate are not listed.
#   - Deprecated manifests are not searched.

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1" # 'Get-Manifest', 'Find-HistoricalVersionsInGit'
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion' (indirectly via Get-Manifest)
. "$PSScriptRoot\..\lib\database.ps1" # 'Get-ScoopDBVersions'
. "$PSScriptRoot\..\lib\download.ps1" # 'Get-UserAgent' (indirectly via Get-Manifest)

$opt, $apps, $err = getopt $args 's:' 'source='
if ($err) { error "scoop versions: $err"; exit 1 }

$source = if ($opt.ContainsKey('s')) { $opt.s } elseif ($opt.ContainsKey('source')) { $opt.source } else { 'all' }
$source = $source.ToLowerInvariant()
if ($source -notin @('all', 'git_history', 'sqlite_cache')) {
    error "scoop versions: invalid --source '$source'. Valid values: all, git_history, sqlite_cache."
    exit 1
}

if (!$apps -or [String]::IsNullOrWhiteSpace($apps[0])) {
    error '<app> missing'
    my_usage
    exit 1
}

if (@($apps).Count -gt 1) {
    error 'scoop versions: only one <app> is supported.'
    my_usage
    exit 1
}

$app_arg = $apps[0]
$null, $null, $requested_version = parse_app $app_arg
if ($null -ne $requested_version) {
    abort "scoop versions: '$app_arg' uses app@version, which is not supported. Use 'scoop versions <app>'."
}

$app, $manifest, $bucket, $url = Get-Manifest $app_arg
if (!$manifest) {
    abort "Could not find manifest for '$app_arg'."
}
if ($url) {
    abort "Historical versions are not available for URL or local manifests."
}
if (!$bucket) {
    abort "No bucket is associated with '$app'; historical versions are unavailable."
}

# The command intentionally only supports active manifests. Get-Manifest can
# fall back to deprecated/ for installed apps, so verify the active path.
$manifest_file = @(manifest_path $app $bucket)
if ($manifest_file.Count -eq 0 -or !(Test-Path -LiteralPath $manifest_file[0])) {
    abort "Manifest for '$app' is not in the active bucket (deprecated manifests are not supported)."
}

$version_map = [System.Collections.Generic.Dictionary[String, Object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$version_order = [System.Collections.Generic.List[String]]::new()

function Add-ScoopVersionEntry($version, $source_name, $commit, $updated) {
    if ([String]::IsNullOrWhiteSpace($version)) { return }

    if ($version_map.ContainsKey($version)) {
        $entry = $version_map[$version]
        $sources = @($entry.Source -split ',')
        if ($sources -notcontains $source_name) {
            $entry.Source = "$($entry.Source),$source_name"
        }
        if (!$entry.Commit -and $commit) { $entry.Commit = $commit }
        if (!$entry.Updated -and $updated) { $entry.Updated = $updated }
        return
    }

    $version_map[$version] = [PSCustomObject]@{
        Version = $version
        Source  = $source_name
        Commit  = $commit
        Updated = $updated
    }
    $version_order.Add($version)
}

if (($source -in @('all', 'git_history')) -and (get_config USE_GIT_HISTORY $true)) {
    try {
        foreach ($item in @(Find-HistoricalVersionsInGit $app $bucket)) {
            Add-ScoopVersionEntry $item.Version 'git_history' $item.Commit $item.Updated
        }
    } catch {
        abort "Could not read Git history: $($_.Exception.Message)"
    }
}

if (($source -in @('all', 'sqlite_cache')) -and (get_config USE_SQLITE_CACHE)) {
    $db_path = Join-Path $scoopdir 'scoop.db'
    $sqlite_driver = "$PSScriptRoot\..\supporting\sqlite\System.Data.SQLite.dll"

    if (!(Test-Path -LiteralPath $db_path)) {
        warn "SQLite cache database not found at '$db_path'; skipping SQLite source."
    } elseif (!('System.Data.SQLite.SQLiteConnection' -as [Type]) -and !(Test-Path -LiteralPath $sqlite_driver)) {
        # Open-ScoopDB downloads the driver when it is missing; a read-only
        # listing command must not have that side effect.
        warn 'SQLite driver not found; skipping SQLite source.'
    } else {
        try {
            foreach ($version in @(Get-ScoopDBVersions -Name $app -Bucket $bucket)) {
                Add-ScoopVersionEntry $version 'sqlite_cache' $null $null
            }
        } catch {
            abort "Could not read SQLite cache: $($_.Exception.Message)"
        }
    }
}

if ($version_map.Count -eq 0) {
    # No results is not an error: a freshly initialized bucket may not have
    # Git history or a cache yet.
    warn "No versions found for '$app' (source: $source)."
    exit 0
}

# Keep the natural source order: Git log order, then SQLite-only versions.
foreach ($version in $version_order) {
    $entry = $version_map[$version]

    [PSCustomObject][ordered]@{
        Version = $entry.Version
        Source  = $entry.Source
        Commit  = $entry.Commit
        Updated = $entry.Updated
    }
}

exit 0
