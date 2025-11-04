function Get-ScriptAst {
    param (
        [string]$Path
    )

    if ((-not $script:ScriptAst)) {
        $script:ScriptAst = @{}
    }

    if (-not $script:ScriptAst[$Path]) {
        $script:ScriptAst[$Path] = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }

    return $script:ScriptAst[$Path]
}

function Get-ScriptFunction {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(ValueFromPipeline)]
        [string]$Path
    )

    begin {
        $DefinedFuncs = @{}
    }

    process {
        # Write-Debug "Parsing $Path..."

        $ScriptAst = Get-ScriptAst -Path $Path
        $FuncDefAst = $ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        $FuncDefAst | ForEach-Object {
            if ($DefinedFuncs.ContainsKey($_.Name)) {
                # Write-Debug "`tDuplicate function: $($_.Name) defined in $Path`:$($_.Extent.StartLineNumber)"
                return
            }

            # Write-Debug "`tFound function: $($_.Name) defined in $Path`:$($_.Extent.StartLineNumber)"

            $DefinedFuncs[$_.Name] = @{
                File = $Path
                Line = $_.Extent.StartLineNumber
            }
        }
    }

    end {
        return $DefinedFuncs
    }
}

function Get-ImportedDependency {
    param (
        [string]$Path
    )

    $ScriptAst = Get-ScriptAst -Path $Path
    $CommandAst = $ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true)

    $ImportedDeps = [System.Collections.ArrayList]::new()

    $CommandAst | ForEach-Object {
        if ($_.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot) {
            return
        }

        $Dependency = $_.CommandElements.Value

        # Workaround for using: prefix in module import. Will be removed in the future.
        $Dependency = $Dependency -replace 'using:', ''

        try {
            $ResolvedPath = $Dependency.Replace('$PSScriptRoot', (Split-Path -Parent $Path))
            $ResolvedDependency = [System.IO.Path]::GetFullPath($ResolvedPath)

            if ($ResolvedDependency -notin $ImportedDeps) {
                $ImportedDeps.Add($ResolvedDependency) | Out-Null
            }
        } catch {
            Write-Warning "`tFailed to resolve dependency path: $Dependency - $($_.Exception.Message)"
        }
    }

    return @($ImportedDeps)
}

function Get-ScriptFunctionCallMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(ValueFromPipeline)]
        [string]$Path
    )

    begin {
        $CallMap = @{}
    }

    process {
        # Write-Debug "Parsing $Path..."

        $ScriptAst = Get-ScriptAst -Path $Path
        $FuncDefAst = $ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

        $FuncDefAst | ForEach-Object {
            $CommandAst = $_.Body.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true)

            $Visited = @{}
            $Invocations = [System.Collections.ArrayList]::new()

            $Caller = $_.Name

            $CommandAst | ForEach-Object {
                $Func = $_.GetCommandName()

                # Workaround for script:url prefix in function calls. Will be removed in the future.
                $Func = $Func -replace 'script:', ''

                if ((-not $Func) -or $Visited[$Func]) {
                    return
                }

                $Visited[$Func] = $true

                $Invocations.Add(@{
                        Name = $Func
                        File = $Path
                        Line = $_.Extent.StartLineNumber
                    }) | Out-Null

                # Write-Debug "`tFound invocation in function $Caller`: $Func."
            }
            $CallMap[$Caller] = @($Invocations)
        }
    }

    end {
        return $CallMap
    }
}

function Get-ScriptFunctionCall {
    param (
        [string]$Path
    )

    $ScriptAst = Get-ScriptAst -Path $Path

    $CommandAst = $ScriptAst.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true)

    $Invocation = [System.Collections.ArrayList]::new()
    $Visited = @{}

    $CommandAst | ForEach-Object {
        $Func = $_.GetCommandName()

        # Workaround for script:url prefix in function calls. Will be removed in the future.
        $Func = $Func -replace 'script:', ''

        if ((-not $Func) -or ($Visited[$Func])) {
            return
        }

        $Visited[$Func] = $true

        $Invocation.Add(@{
                Name = $Func
                File = $Path
                Line = $_.Extent.StartLineNumber
            }) | Out-Null
    }

    return @($Invocation)
}

function Get-DotSourcedDependency {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [string[]] $Libs,
        [Parameter(ValueFromPipeline)]
        [string] $Path
    )

    begin {
        $Deps = @{}
        $LibDefinedFuncs = $Libs | Get-ScriptFunction
        $LibCallMap = $Libs | Get-ScriptFunctionCallMap
    }

    process {
        # Write-Debug "Analyzing dot-sourced dependency for $Path ..."

        $Dependency = @{}

        $DefinedFuncs = Get-ScriptFunction -Path $Path
        $CallMap = Get-ScriptFunctionCallMap -Path $Path

        $Searched = @{}
        $Queue = [System.Collections.Queue]::new()

        # BFS
        Get-ScriptFunctionCall -Path $Path | ForEach-Object {
            $Queue.Enqueue(@{
                    Name      = $_.Name
                    CallStack = [System.Collections.ArrayList]::new(@($_))
                })
            $Searched[$_.Name] = $true
        }

        while ($Queue.Count -gt 0) {
            $Invocation = $Queue.Dequeue()
            $Name = $Invocation.Name

            # Write-Debug "`tFound invocation: $($Invocation.Name)"

            $FuncDefination = $DefinedFuncs[$Name]
            $FuncCallMap = $CallMap[$Name]

            if (-not $FuncDefination) {
                $FuncDefination = $LibDefinedFuncs[$Name]
                $FuncCallMap = $LibCallMap[$Name]
            }

            if (-not $FuncDefination) {
                # Write-Debug "`tFunction $Name not found, maybe it's a system command or from other script"
                continue
            }

            if (($FuncDefination.File -ne $Path) -and (-not $Dependency.ContainsKey($FuncDefination.File))) {
                $Dependency[$FuncDefination.File] = @($Invocation.CallStack)

                # Write-Debug "`t`tFound new dependency: $($FuncDefination.File)"
                $Invocation.CallStack | ForEach-Object {
                    # Write-Debug "`t`tFunction $($_.Name) called at $($_.File) : $($_.Line)"
                }
            }

            $FuncCallMap | Where-Object { $_ -and (-not $Searched[$_.Name]) } | ForEach-Object {
                $Func = $_.Name

                $CallStack = $Invocation.CallStack.Clone()
                $CallStack.Add($_) | Out-Null

                $Searched[$Func] = $true
                $Queue.Enqueue(@{
                        Name      = $Func
                        CallStack = $CallStack
                    })
            }
        }

        $Deps[$Path] = $Dependency
    }

    end {
        return $Deps
    }
}
