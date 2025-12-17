BeforeAll {
    . "$PSScriptRoot\..\lib\core.ps1"
}

Describe 'substitute' -Tag 'Scoop' {
    It 'should properly handle keys that are substrings of other keys' {
        $params = @{}

        # Run repeatedly (10 times) to reduce the likelihood of accidental correct ordering.
        1 .. 10 | ForEach-Object {
            $params["`$name$($_)"] = "$($_).exe"
            $params["`$name$($_)NoExt"] = "$_"

            substitute ("`$name$($_)NoExt") $params $false | Should -Be "$_"
        }
    }
}
