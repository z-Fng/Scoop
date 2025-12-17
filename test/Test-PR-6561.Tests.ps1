BeforeAll {
    . "$PSScriptRoot\..\lib\core.ps1"
}

Describe 'substitute' -Tag 'Scoop' {
    It 'should properly handle keys that are substrings of other keys' {
        $params = @{
            '$url'           = 'https://example.com/download/win-desktop.exe'
            '$urlNoExt'      = 'https://example.com/download/win-desktop'
            '$basename'      = 'win-desktop.exe'
            '$basenameNoExt' = 'win-desktop'
            '$NULL'          = $null
        }

        # Any resize or rehash of a Hashtable can change its enumeration order, as ordering is not guaranteed.
        # Force a larger number of entries to reduce the likelihood of accidental correct ordering.
        1..100 | ForEach-Object {
            $params["__junk$_"] = "$_"
        }

        # substitute '$url.sha256' $null $false | Should -Be '$url.sha256'
        substitute '$url.sha256' $params $false | Should -Be 'https://example.com/download/win-desktop.exe.sha256'
        substitute '$urlNoExt.sha256' $params $false | Should -Be 'https://example.com/download/win-desktop.sha256'
        substitute '$basename.sha256' $params $false | Should -Be 'win-desktop.exe.sha256'
        substitute '$basenameNoExt.sha256' $params $false | Should -Be 'win-desktop.sha256'
        substitute '$NULL.sha256' $params $false | Should -Be '.sha256'
        substitute '$NULL.sha256' $params $true | Should -Be '.sha256'
    }
}
