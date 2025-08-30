BeforeAll {
    . "$PSScriptRoot\..\..\..\lib\core.ps1" # ConvertToPrettyJson
    . "$PSScriptRoot\..\..\..\lib\json.ps1"
    . "$PSScriptRoot\..\..\..\lib\buckets.ps1" # Find-BucketDirectory

    $debug_print = $false

    function New-Manifest {
        param(
            [string] $app,
            [string] $bucket,
            [string] $version,
            [string[]] $script_types,
            [hashtable[]] $vars_info
        )

        $manifest = @{
            'version' = $version
            'url'     = (Get-ManifestPath $app $bucket)
        }

        foreach ($script_type in $script_types) {
            $var_file_path = $(Get-VarFilePath -script_type $script_type)

            $script = @(
                "ensure $(Get-OutputPath)"
                "`$var_actual = @{}"
            )

            foreach ($var_info in $vars_info) {
                $script += "`$var_actual.$($var_info.var_name) = [$($var_info.type)]`$$($var_info.var_name)"
            }

            $script += "`$var_actual | ConvertToPrettyJson | Set-Content -Path $var_file_path"

            if ( ('installer' -eq $script_type) -or ('uninstaller' -eq $script_type) ) {
                $manifest[$script_type] = @{'script' = $script }
            } else {
                $manifest[$script_type] = $script
            }
        }

        $manifest | ConvertToPrettyJson | Set-Content -Path (Get-ManifestPath $app $bucket) -Force
    }

    function Get-ManifestPath {
        param(
            [string]$app,
            [string]$bucket
        )

        return "$(Find-BucketDirectory -Name $bucket)\$app.json"
    }

    function Get-OutputPath() {
        return "$env:TEMP\scoop-test-vars-in-scripts"
    }

    function Get-VarFilePath {
        param(
            [string] $script_type
        )

        return "$(Get-OutputPath)\$script_type.json"
    }

    function Invoke-ScoopCommand {
        param (
            [Parameter(Mandatory = $true)]
            [ValidateSet('install', 'uninstall', 'update')]
            [string] $command,
            [Parameter(Mandatory = $true)]
            [string] $app,
            [Parameter(Mandatory = $true)]
            [bool] $global,
            [bool] $purge
        )

        $args = @($command, $app)

        if ($global) {
            $args += '-g'
        }

        if (($command -eq 'uninstall') -and $purge) {
            $args += '-p'
        }

        $output = &scoop @args *>1

        if ($debug_print) {
            Write-Host $output
        }
    }
}

BeforeDiscovery {
    $app = 'test-vars'
    $bucket = 'main'

    $lower_version = '1.0.0'
    $higher_version = '2.0.0'

    $install_script_types = @('pre_install', 'installer', 'post_install'  )
    $uninstall_script_types = @('pre_uninstall', 'uninstaller', 'post_uninstall')
    $script_types = $install_script_types + $uninstall_script_types

    $cmd_script_types = @{
        install   = $install_script_types
        update    = $script_types
        uninstall = $uninstall_script_types
    }

    $vars_info = @(
        @{var_name = 'app'      ; type = 'string' }
        @{var_name = 'bucket'   ; type = 'string' }
        @{var_name = 'version'  ; type = 'string' }
        @{var_name = 'global'   ; type = 'bool' }
        @{var_name = 'purge'    ; type = 'bool' }
        @{var_name = 'cmd'      ; type = 'string' }
    )

    $testcases = @()

    foreach ($global in @($false, $true)) {
        foreach ($purge in @($false, $true)) {

            $vars_excepted_list = @{}

            foreach ($cmd in $cmd_script_types.Keys) {
                $vars_excepted_list[$cmd] = @()
                foreach ($script_type in $cmd_script_types[$cmd]) {
                    $vars_excepted_info = @()

                    foreach ($var_info in $vars_info) {
                        $var_name = $var_info.var_name
                        $var_excepted_info = @{var_name = $var_name }

                        $var_excepted_info.expected_value = switch ($var_name) {
                            'app' { $app }
                            'bucket' { $bucket }
                            'global' { $global }
                            'cmd' { $cmd }
                            'purge' {
                                if (($cmd -eq 'uninstall') -and ($script_type -in $uninstall_script_types)) {
                                    $purge
                                } else {
                                    $false
                                }
                            }
                            'version' {
                                # if (($cmd -eq "uninstall") -or (($cmd -eq "update") -and ($script_type -in $install_script_types))) {
                                #     $higher_version
                                # } else {
                                #     $lower_version
                                # }

                                if ($cmd -in @('update', 'uninstall')) {
                                    $higher_version
                                } else {
                                    $lower_version
                                }
                            }
                            default { throw }
                        }

                        $vars_excepted_info += $var_excepted_info
                    }

                    $vars_excepted_list[$cmd] += @{
                        script_type        = $script_type
                        vars_excepted_info = $vars_excepted_info
                    }
                }
            }

            $testcases += @{
                app                    = $app
                bucket                 = $bucket

                global                 = $global
                purge                  = $purge

                lower_version          = $lower_version
                higher_version         = $higher_version

                install_script_types   = $install_script_types
                uninstall_script_types = $uninstall_script_types
                script_types           = $script_types

                vars_info              = $vars_info
                vars_excepted_list     = $vars_excepted_list
            }
        }
    }
}

Describe 'Hook Scripts. Global:<global>, Purge:<purge>' -ForEach $testcases {
    BeforeAll {
        Invoke-ScoopCommand -command 'uninstall' -app $app -global $false -purge $true
        Invoke-ScoopCommand -command 'uninstall' -app $app -global $true -purge $true
        Remove-Item (Get-ManifestPath $app $bucket) -Force -ErrorAction Ignore
        Remove-Item (Get-OutputPath) -Recurse -Force -ErrorAction Ignore
    }

    AfterAll {
        Remove-Item (Get-ManifestPath $app $bucket) -Force -ErrorAction Ignore
        Remove-Item (Get-OutputPath) -Recurse -Force -ErrorAction Ignore
    }

    Context 'During [installation]' {
        BeforeAll {
            Remove-Item (Get-OutputPath) -Recurse -Force -ErrorAction Ignore

            New-Manifest -app $app -bucket $bucket -version $lower_version -script_types $script_types -vars_info $vars_info

            Invoke-ScoopCommand -command 'install' -app $app -global $global
        }

        It 'file should exist' -ForEach $script_types {
            if ($_ -in $install_script_types) {
                (Get-VarFilePath -script_type $_) | Should -Exist
            } else {
                (Get-VarFilePath -script_type $_) | Should -Not -Exist
            }
        }

        Context 'in [<script_type>] script' -ForEach $vars_excepted_list['install'] {
            BeforeAll {
                $var_actual = (Get-Content -Path (Get-VarFilePath -script_type $script_type)) | ConvertFrom-Json
            }

            It 'variable [<var_name>] should be [<expected_value>]' -ForEach $vars_excepted_info {
                $actual_value = $var_actual."$var_name"

                if ($debug_print) {
                    Write-Host "$script_type`t$var_name`t`: Expected $expected_value, Got $actual_value."
                }

                $actual_value | Should -Be $expected_value
            }
        }
    }

    Context 'During [update]' {
        BeforeAll {
            Remove-Item (Get-OutputPath) -Recurse -Force -ErrorAction Ignore

            New-Manifest -app $app -bucket $bucket -version $higher_version -script_types $script_types -vars_info $vars_info

            Invoke-ScoopCommand -command 'update' -app $app -global $global
        }

        It 'file should exist' -ForEach $script_types {
            (Get-VarFilePath -script_type $_) | Should -Exist
        }

        Context 'in [<script_type>] script' -ForEach $vars_excepted_list['update'] {
            BeforeAll {
                $var_actual = (Get-Content -Path (Get-VarFilePath -script_type $script_type)) | ConvertFrom-Json
            }

            It 'variable [<var_name>] should be [<expected_value>]' -ForEach $vars_excepted_info {
                $actual_value = $var_actual."$var_name"

                if ($debug_print) {
                    Write-Host "$script_type`t$var_name`t`: Expected $expected_value, Got $actual_value."
                }

                $actual_value | Should -Be $expected_value
            }
        }
    }

    Context 'During [uninstallation]' {
        BeforeAll {
            Remove-Item (Get-OutputPath) -Recurse -Force -ErrorAction Ignore

            Invoke-ScoopCommand -command 'uninstall' -app $app -global $global -purge $purge
        }

        It 'file should exist' -ForEach $script_types {
            if ($_ -in $uninstall_script_types) {
                (Get-VarFilePath -script_type $_) | Should -Exist
            } else {
                (Get-VarFilePath -script_type $_) | Should -Not -Exist
            }
        }

        Context 'in [<script_type>] script' -ForEach $vars_excepted_list['uninstall'] {
            BeforeAll {
                $var_actual = (Get-Content -Path (Get-VarFilePath -script_type $script_type)) | ConvertFrom-Json
            }

            It 'variable [<var_name>] should be [<expected_value>]' -ForEach $vars_excepted_info {
                $actual_value = $var_actual."$var_name"

                if ($debug_print) {
                    Write-Host "$script_type`t$var_name`t`: Expected $expected_value, Got $actual_value."
                }

                $actual_value | Should -Be $expected_value
            }
        }
    }
}
