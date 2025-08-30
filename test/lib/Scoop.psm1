function Install-Scoop {
    <#
    .SYNOPSIS
        Install scoop using new installer.
    #>
    Write-Host 'Installing scoop'
    $f = Join-Path $env:USERPROFILE 'install.ps1'
    Invoke-WebRequest 'https://raw.githubusercontent.com/ScoopInstaller/Install/master/install.ps1' -UseBasicParsing -OutFile $f
    $ENV:SCOOP = "D:\Scoop"
    & $f
    $env:SCOOP_REPO = "https://github.com/z-Fng/Scoop.git"
    $env:SCOOP_BRANCH = "test-hook-vars"
    if ($env:SCOOP_REPO) {
        Write-Host "Switching to repository: ${env:SCOOP_REPO}"
        scoop config scoop_repo $env:SCOOP_REPO
        $needUpdate = $true
    }
    if ($env:SCOOP_BRANCH) {
        Write-Host "Switching to branch: ${env:SCOOP_BRANCH}"
        scoop config scoop_branch $env:SCOOP_BRANCH
        $needUpdate = $true
    }
    if ($needUpdate) {
        scoop update
    }
}

Export-ModuleMember -Function Install-Scoop
