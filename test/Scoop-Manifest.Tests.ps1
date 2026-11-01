BeforeAll {
    . "$PSScriptRoot\..\lib\json.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\buckets.ps1"
    . "$PSScriptRoot\..\lib\database.ps1"
    . "$PSScriptRoot\..\lib\autoupdate.ps1"
}

Describe 'JSON parse and beautify' -Tag 'Scoop' {
    Context 'Parse JSON' {
        It 'success with valid json' {
            $null = & { parse_json "$PSScriptRoot\fixtures\manifest\wget.json" }
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\wget.json"
            $parsed | Should-NotBeNull
        }
        It 'returns null and warns with invalid json' {
            Mock warn {}
            & { parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json" }
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json"
            $parsed | Should-BeNull
            Should-Invoke -CommandName warn -Times 1
        }
    }
    Context 'Beautify JSON' {
        BeforeDiscovery {
            $manifests = (Get-ChildItem "$PSScriptRoot\fixtures\format\formatted" -File -Filter '*.json').Name
        }
        BeforeAll {
            $format = "$PSScriptRoot\fixtures\format"
        }
        It '<_>' -ForEach $manifests {
            $pretty_json = (parse_json "$format\unformatted\$_") | ConvertToPrettyJson
            $correct = (Get-Content "$format\formatted\$_") -join "`r`n"
            $correct.CompareTo($pretty_json) | Should-Be 0
        }
    }
}

Describe 'Handle ARM64 and correctly fallback' -Tag 'Scoop' {
    It 'Should return "arm64" if supported' {
        $manifest1 = @{ url = 'test'; architecture = @{ 'arm64' = @{ pre_install = 'test' } } }
        $manifest2 = @{ url = 'test'; pre_install = "'arm64'" }
        $manifest3 = @{ architecture = @{ 'arm64' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be 'arm64'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be 'arm64'
        Get-SupportedArchitecture $manifest3 'arm64' | Should-Be 'arm64'
    }
    It 'Should return "64bit" if unsupported on Windows 11' {
        $WindowsBuild = 22000
        $manifest1 = @{ url = 'test' }
        $manifest2 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be '64bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be '64bit'
    }
    It 'Should return "32bit" if unsupported on Windows 10' {
        $WindowsBuild = 19044
        $manifest2 = @{ url = 'test' }
        $manifest1 = @{ url = 'test'; architecture = @{ '64bit' = @{ pre_install = 'test' } } }
        $manifest3 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be '32bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be '32bit'
        Get-SupportedArchitecture $manifest3 'arm64' | Should-BeNull
    }
}

Describe 'Manifest Validator' -Tag 'Validator' {
    # Could not use backslash '\' in Linux/macOS for .NET object 'Scoop.Validator'
    BeforeAll {
        Add-Type -Path "$PSScriptRoot\..\supporting\validator\bin\Scoop.Validator.dll"
        $schema = "$PSScriptRoot/../schema.json"
    }

    It 'Scoop.Validator is available' {
        ([System.Management.Automation.PSTypeName]'Scoop.Validator').Type | Should-Be 'Scoop.Validator'
    }
    It 'fails with broken schema' {
        $validator = New-Object Scoop.Validator("$PSScriptRoot/fixtures/manifest/broken_schema.json", $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 1
        $validator.Errors | Select-Object -First 1 | Should-MatchString 'broken_schema.*(line 6).*(position 4)'
    }
    It 'fails with broken manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/broken_wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 1
        $validator.Errors | Select-Object -First 1 | Should-MatchString 'broken_wget.*(line 5).*(position 4)'
    }
    It 'fails with invalid manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/invalid_wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 16
        $validator.Errors | Select-Object -First 1 | Should-MatchString "Property 'randomproperty' has not been defined and the schema does not allow additional properties\."
        $validator.Errors | Select-Object -Last 1 | Should-MatchString 'Required properties are missing from object: version\.'
    }
}

Describe 'Find-HistoricalManifestInCache' -Tag 'Scoop' {
    It 'returns $null when sqlite cache disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'returns manifest text and version when cache has exact match' {
        $tempUM = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Get-ScoopDBItem {
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('manifest')
            $row = $dt.NewRow()
            $row['manifest'] = '{"version":"1.2.3"}'
            [void]$dt.Rows.Add($row)
            Write-Output $dt -NoEnumerate
        }
        Mock ensure {}
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.2.3'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.2.3'
        $result.ManifestText | Should-MatchString '"version":"1.2.3"'
    }
}

Describe 'Find-HistoricalManifestInGit' -Tag 'Scoop' {
    BeforeEach {
        $bucketRoot = 'C:\b\root'
        $innerBucket = 'C:\b\root\bucket'
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $true }
        Mock Find-BucketDirectory -ParameterFilter { $Root } { $bucketRoot }
        Mock Find-BucketDirectory -ParameterFilter { -not $Root } { $innerBucket }
        Mock Test-Path -ParameterFilter { $Path -eq (Join-Path $bucketRoot '.git') } { $true }
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $true }
        Mock Get-ChildItem -ParameterFilter { $LiteralPath -eq $innerBucket } { [pscustomobject]@{ FullName = (Join-Path $innerBucket 'foo.json') } }
    }

    It 'returns $null when git history search disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $false }
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'returns manifest text on version match' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('abcdef0123456789') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.ManifestText | Should-MatchString '"version":"1.0.0"'
    }

    It 'short-circuits via HEAD fast-path when HEAD already has the requested version' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('shouldnotbeused') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.source | Should-Be 'git_manifest:HEAD'
        Should-Invoke -CommandName Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } -Times 0
    }

    It 'falls back to -S pickaxe when -G yields no commits' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } { return @() }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-S' } { return @('feedface') }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -notlike 'HEAD*' } { return '{"version":"1.0.0"}' }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.source | Should-Be 'git_manifest:feedface^'
    }

    It 'returns $null when $h / $h^ walk yields no manifest' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -match '^[a-f0-9]+\^?:' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-n' } { return @('aaaa1111') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'returns $null when inner bucket directory cannot be found' {
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $false }
        Mock warn {}
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }
}

Describe 'Find-HistoricalManifest (orchestrator)' -Tag 'Scoop' {
    It 'returns $null when both cache and git miss' {
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifestInCache { $null }
        Mock Find-HistoricalManifestInGit { $null }
        $result = Find-HistoricalManifest 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }
}

Describe 'Write-ManifestToUserCache' -Tag 'Scoop' {
    It 'writes to $App.json (no version suffix) so downstream install path does not duplicate version' {
        $umdir = Join-Path $env:TEMP ("ScoopUM_" + [guid]::NewGuid().ToString('N'))
        Mock usermanifestsdir { $umdir }
        $p = Write-ManifestToUserCache -App 'foo' -ManifestText '{"version":"1.0.0"}'
        $p | Should-Be (Join-Path $umdir 'foo.json')
        Test-Path $p | Should-BeTrue
        Remove-Item -Recurse -Force $umdir -ErrorAction SilentlyContinue
    }
}

Describe 'generate_user_manifest (history-aware)' -Tag 'Scoop' {
    It 'returns manifest_path when versions match' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '1.0.0' }, 'main', $null }
        Mock manifest_path { 'C:\path\foo.json' }
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\path\foo.json'
    }

    It 'prefers history orchestrator hit (cache) when enabled' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\cache\foo.json'; version = '1.0.0'; source = 'sqlite_exact_match' } }

        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\cache\foo.json'
        Should-Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'falls back to git history when cache misses' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\git\foo.json'; version = '1.0.0'; source = 'git_manifest:hash' } }
        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\git\foo.json'
        Should-Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'uses autoupdate when no history found and autoupdate exists' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0'; autoupdate = @{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate {}
        Mock warn {}
        Mock info {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be (Join-Path $umdir 'foo.json')
        Should-Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -match "No historical manifest found for 'foo@1\.0\.0'; attempting autoupdate" }
    }

    It 'returns $null when autoupdate fails (caller surfaces the error)' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0'; autoupdate = @{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }
        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate { throw 'fail' }
        Mock warn {}
        Mock info {}
        Mock abort { throw 'aborted' }
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-BeNull
        Should-Invoke -CommandName abort -Times 0
    }

    It 'aborts when no history and no autoupdate' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock warn {}
        Mock info {}
        Mock abort { throw 'aborted' }
        { generate_user_manifest 'foo' 'main' '1.0.0' } | Should-Throw
    }
}

Describe 'manifest bucket auto-discovery' -Tag 'Scoop' {
    It 'discovers bucket for bare app name' {
        Mock Get-LocalBucket { @('main') }
        Mock manifest_path { 'C:\fake.json' }
        Mock parse_json { @{ version = '1.0.0' } }
        Mock warn {}
        $m, $b = Find-AppBucket 'foo'
        $b | Should-Be 'main'
        $m.version | Should-Be '1.0.0'
    }

    It 'returns $null when app not found in any bucket' {
        Mock Get-LocalBucket { @('main') }
        Mock manifest_path { 'C:\nonexistent.json' }
        Mock parse_json { $null }
        Mock warn {}
        $m, $b = Find-AppBucket 'foo'
        $m | Should-BeNull
        $b | Should-BeNull
    }

    It 'url used when bucket is null' {
        Mock url_manifest { @{ version = '1.0.0' } }
        $m = manifest 'foo' $null 'https://example.com/foo.json'
        $m.version | Should-Be '1.0.0'
        Should-Invoke url_manifest -Times 1
    }

    It 'normalizes an explicit bucket name' {
        Mock Get-LocalBucket { @('main', 'extras') }
        Mock manifest_path -ParameterFilter { $bucket -eq 'extras' } { 'C:\buckets\extras\bucket\foo.json' }
        Mock parse_json { @{ version = '1.0.0' } }

        $app, $manifest, $bucket, $url = Get-Manifest 'Extras/Foo'

        $bucket | Should-Be 'extras'
        $manifest.version | Should-Be '1.0.0'
    }
}

Describe 'Resolve-BucketName' -Tag 'Scoop' {
    It 'resolves a local bucket name case-insensitively' {
        Mock Get-LocalBucket { @('main', 'extras') }

        Resolve-BucketName 'Extras' | Should-Be 'extras'
    }

    It 'returns the input when no local bucket matches' {
        Mock Get-LocalBucket { @('main') }

        Resolve-BucketName 'unknown' | Should-Be 'unknown'
    }
}

Describe 'Find-HistoricalVersionsInGit' -Tag 'Scoop' {
    BeforeEach {
        $bucketRoot = 'C:\b\root'
        $innerBucket = 'C:\b\root\bucket'
        Mock Find-BucketDirectory -ParameterFilter { $Root } { $bucketRoot }
        Mock Find-BucketDirectory -ParameterFilter { -not $Root } { $innerBucket }
        Mock Test-Path -ParameterFilter { $Path -eq (Join-Path $bucketRoot '.git') } { $true }
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $true }
        Mock Get-ChildItem -ParameterFilter { $LiteralPath -eq $innerBucket } { [pscustomobject]@{ FullName = (Join-Path $innerBucket 'foo.json') } }
        Mock Test-GitAvailable { $true }
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $true }
        $global:LASTEXITCODE = 0
    }

    It 'returns an empty array when Git history is disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $false }
        Mock Invoke-Git { throw 'Git should not be called.' }

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result.Count | Should-Be 0
        Should-Invoke -CommandName Invoke-Git -Times 0
    }

    It 'throws when git log fails' {
        Mock Invoke-Git { $global:LASTEXITCODE = 128; @() }

        { Find-HistoricalVersionsInGit 'foo' 'main' } |
            Should-Throw '*git log failed*exit code 128*'
    }

    It 'uses the manifest filename casing from disk' {
        Mock Get-ChildItem -ParameterFilter { $LiteralPath -eq $innerBucket } { [pscustomobject]@{ FullName = (Join-Path $innerBucket 'foo.json') } }
        Mock Invoke-Git { @() }

        $null = Find-HistoricalVersionsInGit 'Foo' 'main'

        # -ccontains is case-sensitive; -contains would not verify the casing.
        Should-Invoke -CommandName Invoke-Git -Times 1 -ParameterFilter { $ArgumentList -ccontains 'bucket/foo.json' }
    }

    It 'parses versions newest first and skips commits without a version change' {
        $us = [Char]31
        $log = @(
            "__SCOOP_MANIFEST_COMMIT__abc1234${us}2026-10-21 16:32:26${us}Update to 2.0"
            'diff --git a/bucket/foo.json b/bucket/foo.json'
            '+    "version": "2.0",'
            "__SCOOP_MANIFEST_COMMIT__def5678${us}2026-10-06 08:40:15${us}Only hashes changed"
            '-    "hash": "old"'
            '+    "hash": "new"'
            "__SCOOP_MANIFEST_COMMIT__fff0000${us}2026-09-01 00:00:00${us}Update to 1.0"
            '+    "version": "1.0",'
        )
        Mock Invoke-Git { $log }

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result.Count | Should-Be 2
        $result[0].Version | Should-Be '2.0'
        $result[0].Commit | Should-Be 'abc1234'
        $result[0].Updated | Should-Be '2026-10-21 16:32:26'
        $result[1].Version | Should-Be '1.0'
        $result[1].Commit | Should-Be 'fff0000'
        Should-Invoke -CommandName Invoke-Git -Times 1 -ParameterFilter {
            $ArgumentList -ccontains '--date=format-local:%Y-%m-%d %H:%M:%S' -and
            $ArgumentList -ccontains '--format=__SCOOP_MANIFEST_COMMIT__%h%x1f%cd%x1f%s'
        }
    }

    It 'uses the preformatted committer time string' {
        $us = [Char]31
        $log = @(
            "__SCOOP_MANIFEST_COMMIT__abc1234${us}2026-10-21 16:32:26${us}Update to 2.0"
            '+    "version": "2.0",'
        )
        Mock Invoke-Git { $log }

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result[0].Updated | Should-Be '2026-10-21 16:32:26'
    }

    It 'keeps the newest commit when a version was reverted' {
        $us = [Char]31
        $log = @(
            "__SCOOP_MANIFEST_COMMIT__c333333${us}2026-10-30 00:00:00${us}Revert to 1.0"
            '+    "version": "1.0",'
            "__SCOOP_MANIFEST_COMMIT__c222222${us}2026-10-20 00:00:00${us}Update to 2.0"
            '+    "version": "2.0",'
            "__SCOOP_MANIFEST_COMMIT__c111111${us}2026-10-10 00:00:00${us}Initial 1.0"
            '+    "version": "1.0",'
        )
        Mock Invoke-Git { $log }

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result.Count | Should-Be 2
        $result[0].Version | Should-Be '1.0'
        $result[0].Commit | Should-Be 'c333333'
        $result[1].Version | Should-Be '2.0'
        $result[1].Commit | Should-Be 'c222222'
    }

    It 'returns an empty array when Git is unavailable' {
        Mock Test-GitAvailable { $false }
        Mock warn {}

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result.Count | Should-Be 0
        Should-Invoke warn -Times 1 -ParameterFilter { $msg -match 'Git is not available' }
    }

    It 'returns an empty array when the bucket is not a Git repository' {
        Mock Test-Path -ParameterFilter { $Path -eq (Join-Path $bucketRoot '.git') } { $false }
        Mock warn {}

        $result = @(Find-HistoricalVersionsInGit 'foo' 'main')

        $result.Count | Should-Be 0
        Should-Invoke warn -Times 1 -ParameterFilter { $msg -match 'not a git repository' }
    }
}
