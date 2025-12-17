BeforeAll {
    . "$PSScriptRoot\..\lib\core.ps1"
}

Describe 'substitute' -Tag 'Scoop' {
    It 'should properly handle keys that are substrings of other keys' {
        $params = @{}

        # Force a larger number of entries to reduce the likelihood of accidentally correct ordering.
        1 .. 100 | ForEach-Object {
            $params['Name_{0}' -f $_] = "$($_).exe"
            $params['Name_{0}_NoExt' -f $_] = "$($_)"

            substitute ('Name_{0}_NoExt' -f $_) $params $false | Should -Be "$($_)"
        }
    }
}
