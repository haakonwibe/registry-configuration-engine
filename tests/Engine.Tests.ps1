# Pester 5 tests for Invoke-RegistryConfigEngine.ps1
# Run with: Invoke-Pester -Path .\tests
#
# The engine is dot-sourced under the dot-source guard, so only its functions
# are loaded — no main execution. This requires Pester 5+.

BeforeAll {
    $script:EnginePath = Join-Path $PSScriptRoot '..' 'Invoke-RegistryConfigEngine.ps1' | Resolve-Path
    . $script:EnginePath

    # Two entries meaning the same thing must be accepted *and* reported as a
    # redundant duplicate. Asserting only 'does not throw' would keep passing if
    # the duplicate check were deleted outright, so every acceptance case pins the
    # warning it is supposed to produce rather than just the absence of an error.
    function Assert-RedundantDuplicate {
        param(
            [Parameter(Mandatory)] $Config,
            [int]$Count = 1
        )
        $warnings = $null
        Assert-ValidConfig -Config $Config -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be $Count
        "$warnings" | Should -Match 'no effect'
    }

    # A conflict warns too - it does not throw. Deciding that two entries disagree
    # takes a model of the whole runtime, and a wrong answer used to reject a working
    # config outright; the config now goes through carrying the warning.
    function Assert-ConflictingDuplicate {
        param(
            [Parameter(Mandatory)] $Config,
            [int]$Count = 1
        )
        $warnings = $null
        { Assert-ValidConfig -Config $Config -WarningAction SilentlyContinue } | Should -Not -Throw
        Assert-ValidConfig -Config $Config -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be $Count
        "$warnings" | Should -Match 'appear to disagree'
    }
}

Describe 'Convert-RegistryValue' {

    Context 'DWord / QWord' {
        It 'returns int for DWord' {
            (Convert-RegistryValue -Type 'dword' -Value 42) | Should -Be 42
            (Convert-RegistryValue -Type 'dword' -Value 42).GetType().Name | Should -Be 'Int32'
        }

        It 'returns long for QWord' {
            (Convert-RegistryValue -Type 'qword' -Value 12345678901234).GetType().Name | Should -Be 'Int64'
        }

        It 'wraps DWord values above Int32.MaxValue to their bit pattern' {
            # 0xFFFFFFFF is a common policy sentinel; registry stores it as Int32 -1
            (Convert-RegistryValue -Type 'dword' -Value 4294967295) | Should -Be (-1)
            (Convert-RegistryValue -Type 'dword' -Value 2147483648) | Should -Be ([int]::MinValue)
        }

        It 'rejects values beyond the DWord range' {
            { Convert-RegistryValue -Type 'dword' -Value 4294967296 } | Should -Throw
        }

        It 'wraps QWord values above Int64.MaxValue to their bit pattern' {
            (Convert-RegistryValue -Type 'qword' -Value ([uint64]::MaxValue)) | Should -Be (-1)
        }
    }

    Context 'String / ExpandString' {
        It 'returns string passthrough' {
            (Convert-RegistryValue -Type 'string' -Value 'hello') | Should -Be 'hello'
        }
        It 'expandstring same as string' {
            (Convert-RegistryValue -Type 'expandstring' -Value '%TEMP%\foo') | Should -Be '%TEMP%\foo'
        }
    }

    Context 'Binary' {
        It 'parses comma-separated hex' {
            $bytes = Convert-RegistryValue -Type 'binary' -Value 'FF,00,AB'
            $bytes | Should -BeOfType [byte]
            $bytes.Count | Should -Be 3
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0x00
            $bytes[2] | Should -Be 0xAB
        }

        It 'parses continuous hex string' {
            $bytes = Convert-RegistryValue -Type 'binary' -Value 'FF00AB'
            $bytes.Count | Should -Be 3
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0x00
            $bytes[2] | Should -Be 0xAB
        }

        It 'parses 0x-prefixed hex string' {
            $bytes = Convert-RegistryValue -Type 'binary' -Value '0xDEADBE'
            $bytes.Count | Should -Be 3
            $bytes[0] | Should -Be 0xDE
            $bytes[1] | Should -Be 0xAD
            $bytes[2] | Should -Be 0xBE
        }

        It 'accepts numeric arrays' {
            $bytes = Convert-RegistryValue -Type 'binary' -Value @(60, 0, 0, 0)
            $bytes.Count | Should -Be 4
            $bytes[0] | Should -Be 60
        }

        It 'rejects invalid hex chars in comma-separated form' {
            { Convert-RegistryValue -Type 'binary' -Value 'FF,GG,01' } | Should -Throw
        }

        It 'rejects odd-length continuous hex string' {
            { Convert-RegistryValue -Type 'binary' -Value 'FFA' } | Should -Throw
        }

        # This is the regression case that motivated the regex split:
        # the old regex matched both forms and would crash on continuous
        # multi-byte hex strings.
        It 'does not misroute continuous hex into the comma branch' {
            $bytes = Convert-RegistryValue -Type 'binary' -Value 'DEADBEEF'
            $bytes.Count | Should -Be 4
        }
    }

    Context 'MultiString' {
        It 'wraps single string in array' {
            $r = Convert-RegistryValue -Type 'multistring' -Value 'one'
            $r.GetType().Name | Should -Be 'String[]'
            $r.Count | Should -Be 1
            $r[0] | Should -Be 'one'
        }
        It 'passes through array' {
            $r = Convert-RegistryValue -Type 'multistring' -Value @('a', 'b', 'c')
            $r.Count | Should -Be 3
            $r[1] | Should -Be 'b'
        }
    }

    Context 'Unsupported types' {
        It 'throws on unknown type' {
            { Convert-RegistryValue -Type 'magic' -Value 1 } | Should -Throw
        }
    }
}

Describe 'Expand-ConfigVariables' {

    It 'expands {{DATE}}' {
        $expected = Get-Date -Format 'yyyy-MM-dd'
        (Expand-ConfigVariables -Value '{{DATE}}') | Should -Be $expected
    }

    It 'expands {{COMPUTERNAME}}' {
        (Expand-ConfigVariables -Value 'host:{{COMPUTERNAME}}') | Should -Be "host:$env:COMPUTERNAME"
    }

    It 'expands multiple variables in one string' {
        $r = Expand-ConfigVariables -Value '{{COMPUTERNAME}} on {{DATE}}'
        $r | Should -Match "$env:COMPUTERNAME on \d{4}-\d{2}-\d{2}"
    }

    It 'leaves non-variable strings alone' {
        (Expand-ConfigVariables -Value 'literal value') | Should -Be 'literal value'
    }

    It 'walks arrays of strings (multistring)' {
        $r = Expand-ConfigVariables -Value @('a-{{COMPUTERNAME}}', 'b-{{DATE}}')
        $r.Count | Should -Be 2
        $r[0] | Should -Be "a-$env:COMPUTERNAME"
        $r[1] | Should -Match '^b-\d{4}-\d{2}-\d{2}$'
    }

    It 'leaves byte arrays alone' {
        $bytes = [byte[]]@(60, 0, 0, 0)
        $r = Expand-ConfigVariables -Value $bytes
        $r.GetType().Name | Should -Be 'Byte[]'
        $r.Count | Should -Be 4
        $r[0] | Should -Be 60
    }

    It 'returns non-string scalars unchanged' {
        (Expand-ConfigVariables -Value 42) | Should -Be 42
    }
}

Describe 'Test-ByteArrayEqual' {

    It 'matches identical byte arrays' {
        Test-ByteArrayEqual -First ([byte[]]@(0xDE, 0xAD)) -Second ([byte[]]@(0xDE, 0xAD)) | Should -Be $true
    }

    It 'is order-sensitive (regression: Compare-Object treated permutations as equal)' {
        Test-ByteArrayEqual -First ([byte[]]@(0xFF, 0x00)) -Second ([byte[]]@(0x00, 0xFF)) | Should -Be $false
    }

    It 'rejects different lengths and nulls' {
        Test-ByteArrayEqual -First ([byte[]]@(1, 2)) -Second ([byte[]]@(1, 2, 3)) | Should -Be $false
        Test-ByteArrayEqual -First $null -Second ([byte[]]@(1)) | Should -Be $false
    }
}

Describe 'ConvertTo-UnsignedNumber' {

    It 'reinterprets negative DWord as unsigned' {
        ConvertTo-UnsignedNumber -Type 'dword' -Value (-1) | Should -Be 4294967295
    }

    It 'leaves positive DWord unchanged' {
        ConvertTo-UnsignedNumber -Type 'dword' -Value 100 | Should -Be 100
    }

    It 'reinterprets negative QWord as unsigned' {
        ConvertTo-UnsignedNumber -Type 'qword' -Value (-1L) | Should -Be ([uint64]::MaxValue)
    }

    It 'accepts an already-unsigned UInt32 DWord (as the provider returns it)' {
        ConvertTo-UnsignedNumber -Type 'dword' -Value ([uint32]4294967295) | Should -Be 4294967295
    }

    It 'accepts an already-unsigned UInt64 QWord without overflowing [long]' {
        ConvertTo-UnsignedNumber -Type 'qword' -Value ([uint64]::MaxValue) | Should -Be ([uint64]::MaxValue)
    }

    It 'passes non-numeric types through' {
        ConvertTo-UnsignedNumber -Type 'string' -Value 'abc' | Should -Be 'abc'
    }
}

Describe 'Compare-RegistryValue' {

    Context 'Existence checks' {
        It 'Exists returns Match=true when value present' {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ MyValue = 'x' } } -ParameterFilter { $Name -eq 'MyValue' }

            $r = Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'MyValue' -Type 'String' -Comparison 'Exists'
            $r.Match | Should -Be $true
        }

        It 'NotExists returns Match=true when value absent' {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { $null }

            $r = Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Missing' -Type 'String' -Comparison 'NotExists'
            $r.Match | Should -Be $true
        }
    }

    Context 'Equals — case-insensitive default' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ V = 'Hello' } } -ParameterFilter { $Name -eq 'V' }
        }

        It 'matches identical strings' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue 'Hello').Match | Should -Be $true
        }

        It 'matches case-different strings by default' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue 'HELLO').Match | Should -Be $true
        }

        It 'does not match when CaseSensitive=true and case differs' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue 'HELLO' -CaseSensitive $true).Match | Should -Be $false
        }

        It 'matches when CaseSensitive=true and case is identical' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue 'Hello' -CaseSensitive $true).Match | Should -Be $true
        }
    }

    Context 'Numeric comparisons' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ Version = 100 } } -ParameterFilter { $Name -eq 'Version' }
        }

        It 'GreaterThanOrEqual: 100 >= 50 is true' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Version' -Type 'DWord' -ExpectedValue 50 -Comparison 'GreaterThanOrEqual').Match | Should -Be $true
        }
        It 'GreaterThanOrEqual: 100 >= 200 is false' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Version' -Type 'DWord' -ExpectedValue 200 -Comparison 'GreaterThanOrEqual').Match | Should -Be $false
        }
        It 'LessThan: 100 < 200 is true' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Version' -Type 'DWord' -ExpectedValue 200 -Comparison 'LessThan').Match | Should -Be $true
        }
    }

    Context 'Equals on high-bit DWord/QWord' {
        # The PowerShell registry provider returns Int32/Int64 while the high bit is
        # clear but UInt32/UInt64 once it is set, whereas Convert-RegistryValue produces
        # the signed bit pattern (0xFFFFFFFF -> -1). Comparing those raw never matched,
        # so e.g. SCHANNEL's Enabled = 0xFFFFFFFF stayed non-compliant forever and
        # Intune re-ran remediation on every cycle.
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ D = [uint32]4294967295 } } -ParameterFilter { $Name -eq 'D' }
            Mock Get-ItemProperty { [PSCustomObject]@{ B = [uint32]2147483648 } } -ParameterFilter { $Name -eq 'B' }
            Mock Get-ItemProperty { [PSCustomObject]@{ Q = [uint64]::MaxValue } }  -ParameterFilter { $Name -eq 'Q' }
        }

        It 'matches DWord 0xFFFFFFFF written as decimal 4294967295' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'D' -Type 'DWord' -ExpectedValue 4294967295).Match | Should -Be $true
        }
        It 'matches DWord 0xFFFFFFFF written as -1' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'D' -Type 'DWord' -ExpectedValue (-1)).Match | Should -Be $true
        }
        It 'still rejects a genuinely different high DWord' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'D' -Type 'DWord' -ExpectedValue 4294967294).Match | Should -Be $false
        }
        It 'still rejects a small DWord against a high stored value' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'D' -Type 'DWord' -ExpectedValue 0).Match | Should -Be $false
        }
        It 'matches at the 0x80000000 boundary' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'B' -Type 'DWord' -ExpectedValue 2147483648).Match | Should -Be $true
        }
        It 'NotEquals is false when the high DWord does match' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'D' -Type 'DWord' -ExpectedValue 4294967295 -Comparison 'NotEquals').Match | Should -Be $false
        }
        It 'matches QWord 0xFFFFFFFFFFFFFFFF written as decimal' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Q' -Type 'QWord' -ExpectedValue ([uint64]::MaxValue)).Match | Should -Be $true
        }
        It 'GreaterThan on a UInt64 stored value does not overflow' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Q' -Type 'QWord' -ExpectedValue 100 -Comparison 'GreaterThan').Match | Should -Be $true
        }
    }

    Context 'String operators' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ Url = 'https://contoso.example.com/api' } } -ParameterFilter { $Name -eq 'Url' }
        }

        It 'Contains finds substring (case-insensitive default)' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Url' -Type 'String' -ExpectedValue 'CONTOSO' -Comparison 'Contains').Match | Should -Be $true
        }
        It 'StartsWith with CaseSensitive rejects case difference' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Url' -Type 'String' -ExpectedValue 'HTTPS' -Comparison 'StartsWith' -CaseSensitive $true).Match | Should -Be $false
        }
        It 'EndsWith matches' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Url' -Type 'String' -ExpectedValue '/api' -Comparison 'EndsWith').Match | Should -Be $true
        }
    }

    Context 'String operators treat wildcard characters literally' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ V = 'item[1] and more' } } -ParameterFilter { $Name -eq 'V' }
        }

        It 'Contains matches literal brackets (regression: -like interpreted them as wildcards)' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue '[1]' -Comparison 'Contains').Match | Should -Be $true
        }
        It 'Contains does not treat * as match-everything' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue '*' -Comparison 'Contains').Match | Should -Be $false
        }
        It 'StartsWith matches literal bracket prefix' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'V' -Type 'String' -ExpectedValue 'item[1]' -Comparison 'StartsWith').Match | Should -Be $true
        }
    }

    Context 'Binary equality is order-sensitive' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ Bin = [byte[]]@(0xFF, 0x00) } } -ParameterFilter { $Name -eq 'Bin' }
        }

        It 'Equals rejects same bytes in different order' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Bin' -Type 'Binary' -ExpectedValue '00,FF').Match | Should -Be $false
        }
        It 'Equals matches identical byte sequence' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Bin' -Type 'Binary' -ExpectedValue 'FF,00').Match | Should -Be $true
        }
        It 'NotEquals detects permuted bytes as different' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Bin' -Type 'Binary' -ExpectedValue '00,FF' -Comparison 'NotEquals').Match | Should -Be $true
        }
    }

    Context 'Numeric comparisons are unsigned' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            # 0xFFFFFFFF reads back from the registry as Int32 -1
            Mock Get-ItemProperty { [PSCustomObject]@{ Sentinel = -1 } } -ParameterFilter { $Name -eq 'Sentinel' }
        }

        It '0xFFFFFFFF is GreaterThan 100 (regression: signed compare said no)' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Sentinel' -Type 'DWord' -ExpectedValue 100 -Comparison 'GreaterThan').Match | Should -Be $true
        }
        It '0xFFFFFFFF is not LessThanOrEqual 100' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Sentinel' -Type 'DWord' -ExpectedValue 100 -Comparison 'LessThanOrEqual').Match | Should -Be $false
        }
        It 'reports both operands in the same representation (not "4294967295 >= -1")' {
            # The reason string is what lands in the log and Event Log, so it must not
            # mix the unsigned read-back with the signed bit pattern of the expectation.
            $r = Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Sentinel' -Type 'DWord' -ExpectedValue 4294967295 -Comparison 'GreaterThanOrEqual'
            $r.Match  | Should -Be $true
            $r.Reason | Should -Be 'Value 4294967295 >= 4294967295'
            $r.Reason | Should -Not -Match '-1'
        }
    }

    Context 'MultiString equality honors CaseSensitive' {
        BeforeAll {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKLM:\Fake' }
            Mock Get-ItemProperty { [PSCustomObject]@{ Items = @('Alpha', 'Beta') } } -ParameterFilter { $Name -eq 'Items' }
        }

        It 'matches case-insensitive by default' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Items' -Type 'MultiString' -ExpectedValue @('alpha', 'BETA')).Match | Should -Be $true
        }
        It 'CaseSensitive rejects case difference in any element' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Items' -Type 'MultiString' -ExpectedValue @('alpha', 'BETA') -CaseSensitive $true).Match | Should -Be $false
        }
        It 'CaseSensitive accepts exact match' {
            (Compare-RegistryValue -Path 'HKLM:\Fake' -Name 'Items' -Type 'MultiString' -ExpectedValue @('Alpha', 'Beta') -CaseSensitive $true).Match | Should -Be $true
        }
    }

    Context 'Missing key/value' {
        It 'returns Match=false when key does not exist' {
            Mock Test-Path { $false }
            $r = Compare-RegistryValue -Path 'HKLM:\Nope' -Name 'V' -Type 'String' -ExpectedValue 'x'
            $r.Match | Should -Be $false
            $r.Reason | Should -Match 'Key does not exist'
        }
    }
}

Describe 'Assert-ValidConfig (shared validator)' {
    # This is the function New-IntunePackage.ps1 dot-sources and calls directly, so
    # exercise it against parsed config objects the way the generator does.

    It 'accepts a valid config object' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
    }

    It 'throws on an invalid scope' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Banana","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Throw "*scope*"
    }

    It 'throws on an invalid value type' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"Dword32","data":1}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Throw "*invalid type*"
    }

    It 'defaults a missing action to Set (mutates the setting in place)' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","values":[{"name":"V","type":"DWord","data":1}]}]}' | ConvertFrom-Json
        Assert-ValidConfig -Config $cfg
        $cfg.settings[0].action | Should -Be 'Set'
    }

    It 'rejects an empty value name (must use (default))' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"","type":"String","data":"x"}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Throw "*(default)*"
    }

    It 'accepts (default) as a value name' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"(default)","type":"String","data":"x"}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
    }

    It 'rejects a numeric comparison on a String type' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"5","comparison":"GreaterThan"}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Throw "*numeric comparison*"
    }

    It 'rejects a string comparison on a DWord type' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1,"comparison":"Contains"}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Throw "*string comparison*"
    }

    It 'accepts a numeric comparison on a DWord type' {
        $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":100,"comparison":"GreaterThanOrEqual"}]}]}' | ConvertFrom-Json
        { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
    }

    Context 'Duplicate value names in one key' {
        # A .reg holding the same key section twice merges into one group with the
        # name repeated. Entries that disagree can never all be satisfied, so
        # remediation rewrites and detection re-fails forever.

        It 'rejects the same name declared twice with different data' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SYSTEM\\...\\Hashes\\MD5","action":"Set","values":[{"name":"Enabled","type":"DWord","data":4294967295},{"name":"Enabled","type":"DWord","data":0}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'matches names case-insensitively, as the registry does' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"Enabled","type":"DWord","data":1},{"name":"enabled","type":"DWord","data":0}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'rejects a duplicate that differs only by type' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"String","data":1}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'rejects a duplicate that differs only by comparison' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"DWord","data":1,"comparison":"NotExists"}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'warns but accepts an identical duplicate (redundant, not unsatisfiable)' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"DWord","data":1}]}]}' | ConvertFrom-Json
            { Assert-ValidConfig -Config $cfg -WarningAction SilentlyContinue } | Should -Not -Throw
            $w = $null
            Assert-ValidConfig -Config $cfg -WarningVariable w -WarningAction SilentlyContinue
            $w.Count | Should -Be 1
            "$w" | Should -Match 'no effect'
        }

        It 'treats an omitted optional field as its default when matching' {
            # comparison defaults to Equals, so stating it explicitly is the same entry
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"DWord","data":1,"comparison":"Equals","skipDetection":false}]}]}' | ConvertFrom-Json
            Assert-RedundantDuplicate -Config $cfg
        }

        It 'compares string data case-sensitively (different literal, different write)' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"Hello"},{"name":"V","type":"String","data":"hello"}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'allows the same name under two different keys' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\A","action":"Set","values":[{"name":"Enabled","type":"DWord","data":1}]},{"scope":"Machine","path":"SOFTWARE\\B","action":"Set","values":[{"name":"Enabled","type":"DWord","data":0}]}]}' | ConvertFrom-Json
            { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
        }

        It 'handles MultiString array data without tripping over the array' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"MultiString","data":["a","b"]},{"name":"V","type":"MultiString","data":["a","c"]}]}]}' | ConvertFrom-Json
            Assert-ConflictingDuplicate -Config $cfg
        }

        It 'allows a DeleteKey group, which carries no values at all' {
            $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"DeleteKey"}]}' | ConvertFrom-Json
            { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
        }

        Context 'Entries that write the same value in different notations' {
            # Regression: comparing raw JSON called these "disagreeing" when all of
            # them resolve to the identical registry write. Reachable in practice -
            # ConvertFrom-RegistryExport emitted -1 before v1.2.2 and 4294967295
            # after, so concatenating an old converted config with a new one
            # produces exactly this pair.

            It 'treats DWord -1 and 4294967295 as the same instruction' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":4294967295},{"name":"V","type":"DWord","data":-1}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'treats DWord 4294967295 and "0xffffffff" as the same instruction' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":4294967295},{"name":"V","type":"DWord","data":"0xffffffff"}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'treats Binary comma-hex and continuous-hex as the same instruction' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"Binary","data":"3C,00,00,00"},{"name":"V","type":"Binary","data":"3C000000"}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'still rejects Binary values that differ in byte order' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"Binary","data":"3C,00,00,00"},{"name":"V","type":"Binary","data":"00,3C,00,00"}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }

            It 'still rejects a genuine numeric disagreement' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":4294967295},{"name":"V","type":"DWord","data":4294967294}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }

            It 'rejects values differing only by a collation-ignorable character' {
                # 'ab' vs 'a<soft hyphen>b' are different registry writes, but
                # PowerShell's -ceq calls them equal because linguistic collation
                # ignores the character - the comparison has to be ordinal.
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"ab"},{"name":"V","type":"String","data":"a­b"}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }

            It 'falls back to the raw form when data cannot be converted' {
                # Malformed hex - the duplicate check must not turn this into a
                # confusing conflict error; the runtime converter reports it properly.
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"Binary","data":"ZZ,00"},{"name":"V","type":"Binary","data":"ZZ,00"}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }
        }

        Context 'Fields that carry no instruction for the entry that holds them' {
            # An inert field must not distinguish two entries: the pair behaves
            # identically at runtime, so calling them a conflict rejects a config
            # that works.

            It 'ignores type and data for NotExists, which deletes rather than writes' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1,"comparison":"NotExists"},{"name":"V","comparison":"NotExists"}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'ignores caseSensitive on types that never read it' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1,"caseSensitive":true},{"name":"V","type":"DWord","data":1,"caseSensitive":false}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'ignores caseSensitive under a comparison that never reads it' {
                # Exists is answered from the value's presence alone, so the flag
                # changes nothing about detection or the write.
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"a","comparison":"Exists","caseSensitive":true},{"name":"V","type":"String","data":"a","comparison":"Exists","caseSensitive":false}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'still honours caseSensitive where both the type and the comparison read it' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"a","caseSensitive":true},{"name":"V","type":"String","data":"a","caseSensitive":false}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }
        }

        Context 'Boolean flags are read the way the engine reads them' {
            # [bool]'false' is $true, but detect/remediate ask 'false' -eq $true,
            # which is $false. A [bool] cast in the signature would call these two
            # entries a conflict when both are case-insensitive at runtime - and,
            # worse, call caseSensitive:"yes" and caseSensitive:true identical when
            # only the second one is honoured.

            It 'agrees with the runtime on a non-boolean caseSensitive' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"String","data":"a","caseSensitive":"false"},{"name":"V","type":"String","data":"a","caseSensitive":false}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'agrees with the runtime on a non-boolean skipDetection' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1,"skipDetection":"false"},{"name":"V","type":"DWord","data":1,"skipDetection":false}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }
        }

        Context 'The same key declared by more than one setting group' {
            # Nothing stops two groups naming the same scope+path, and a value
            # declared in both fights exactly as it would inside one group.

            It 'rejects contradictory declarations split across two groups' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]},{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":2}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }

            It 'groups paths that differ only by a trailing separator' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]},{"scope":"Machine","path":"SOFTWARE\\X\\","action":"Set","values":[{"name":"V","type":"DWord","data":2}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }

            It 'keeps the same path under different scopes apart' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]},{"scope":"User","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":2}]}]}' | ConvertFrom-Json
                { Assert-ValidConfig -Config $cfg } | Should -Not -Throw
            }

            It 'rejects a value one group writes and another deletes' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]},{"scope":"Machine","path":"SOFTWARE\\X","action":"Delete","values":[{"name":"V"}]}]}' | ConvertFrom-Json
                Assert-ConflictingDuplicate -Config $cfg
            }
        }

        Context 'Actions that do not read the value fields' {
            # Delete reads only the name; DeleteKey ignores 'values' altogether.
            # Comparing type/data there reports a conflict between entries that do
            # precisely the same thing.

            It 'accepts Delete entries that differ only in type and data' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Delete","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"String","data":"a"}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'accepts a Delete entry with no type beside one that has one' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Delete","values":[{"name":"V"},{"name":"V","type":"DWord","data":0}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'treats Delete and a Set/NotExists as the same instruction' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","comparison":"NotExists"}]},{"scope":"Machine","path":"SOFTWARE\\X","action":"Delete","values":[{"name":"V","type":"DWord","data":1}]}]}' | ConvertFrom-Json
                Assert-RedundantDuplicate -Config $cfg
            }

            It 'ignores leftover values on a DeleteKey group' {
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"DeleteKey","values":[{"name":"V","type":"DWord","data":1},{"name":"V","type":"DWord","data":2}]}]}' | ConvertFrom-Json
                $w = $null
                Assert-ValidConfig -Config $cfg -WarningVariable w -WarningAction SilentlyContinue
                $w.Count | Should -Be 0
            }
        }

        Context 'Value names that collation would merge' {
            It 'keeps two names apart when they differ only by an ignorable character' {
                # 'ab' and 'a<soft hyphen>b' are two distinct registry values, but a
                # PowerShell @{} literal keys on CurrentCultureIgnoreCase and would
                # collide them into a bogus conflict.
                $cfg = '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"ab","type":"DWord","data":1},{"name":"a­b","type":"DWord","data":2}]}]}' | ConvertFrom-Json
                $w = $null
                Assert-ValidConfig -Config $cfg -WarningVariable w -WarningAction SilentlyContinue
                $w.Count | Should -Be 0
            }
        }
    }
}

Describe 'Get-ValueSignature' {

    It 'produces one signature per distinct instruction, not per notation' {
        $a = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 4294967295 }
        $b = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = -1 }
        $c = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 0 }
        (Get-ValueSignature -Value $a) | Should -BeExactly (Get-ValueSignature -Value $b)
        (Get-ValueSignature -Value $a) | Should -Not -BeExactly (Get-ValueSignature -Value $c)
    }

    It 'keeps string case significant (remediation writes the literal)' {
        $a = [pscustomobject]@{ name = 'V'; type = 'String'; data = 'Hello' }
        $b = [pscustomobject]@{ name = 'V'; type = 'String'; data = 'hello' }
        (Get-ValueSignature -Value $a) | Should -Not -BeExactly (Get-ValueSignature -Value $b)
    }

    It 'does not let MultiString element splits collide' {
        $a = [pscustomobject]@{ name = 'V'; type = 'MultiString'; data = @('a', 'bc') }
        $b = [pscustomobject]@{ name = 'V'; type = 'MultiString'; data = @('ab', 'c') }
        (Get-ValueSignature -Value $a) | Should -Not -BeExactly (Get-ValueSignature -Value $b)
    }

    It 'applies engine defaults so an omitted optional field matches an explicit one' {
        $a = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 1 }
        $b = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 1; comparison = 'Equals'; skipDetection = $false }
        (Get-ValueSignature -Value $a) | Should -BeExactly (Get-ValueSignature -Value $b)
    }

    It 'collapses every Delete entry to one instruction, whatever it carries' {
        $a = [pscustomobject]@{ name = 'V' }
        $b = [pscustomobject]@{ name = 'V'; type = 'String'; data = 'x'; comparison = 'Contains'; caseSensitive = $true }
        (Get-ValueSignature -Value $a -Action Delete) | Should -BeExactly (Get-ValueSignature -Value $b -Action Delete)
    }

    It 'gives a Delete the same instruction as a Set/NotExists' {
        $a = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 1 }
        $b = [pscustomobject]@{ name = 'V'; comparison = 'NotExists' }
        (Get-ValueSignature -Value $a -Action Delete) | Should -BeExactly (Get-ValueSignature -Value $b)
    }

    It 'defaults to Set so a plain call still describes a write' {
        $a = [pscustomobject]@{ name = 'V'; type = 'DWord'; data = 1 }
        (Get-ValueSignature -Value $a) | Should -Not -BeExactly (Get-ValueSignature -Value $a -Action Delete)
    }
}

Describe 'Fatal error output' {
    # The top-level catch calls exit, so the engine has to be run as a child
    # process here rather than dot-sourced.

    BeforeEach {
        $script:TmpConfig = Join-Path $env:TEMP "rce-fatal-$(Get-Random).json"
        '{"version":"1.0","settings":[{"scope":"Banana","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TmpConfig -Force -ErrorAction SilentlyContinue
    }

    It 'tags each line once (regression: the prefix was printed twice)' {
        $out = & powershell.exe -NoProfile -File $script:EnginePath -ConfigPath $script:TmpConfig -Mode Validate 2>&1 | Out-String
        $out | Should -Match 'ERROR'
        # No single line may carry the prefix more than once
        $out | Should -Not -Match "(?m)^.*\[REGENGINE\].*\[REGENGINE\].*$"
    }

    It 'still reports the reason and the ConfigError exit code' {
        & powershell.exe -NoProfile -File $script:EnginePath -ConfigPath $script:TmpConfig -Mode Validate *>$null
        $LASTEXITCODE | Should -Be 3
    }
}

Describe 'Get-Configuration validation' {

    BeforeEach {
        $script:TmpConfig = Join-Path $env:TEMP "rce-cfg-$(Get-Random).json"
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TmpConfig -Force -ErrorAction SilentlyContinue
    }

    It 'rejects a Set group without values (silent no-op typo)' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set"}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*values*"
    }

    It 'rejects a group with a missing action and no values (action defaults to Set)' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X"}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*values*"
    }

    It 'accepts a DeleteKey group without values' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"DeleteKey"}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig } | Should -Not -Throw
    }

    It 'rejects an unknown scope' {
        '{"version":"1.0","settings":[{"scope":"Banana","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*scope*"
    }

    It 'rejects an unknown action' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Nuke","values":[{"name":"V","type":"DWord","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*action*"
    }

    It 'rejects a path containing wildcard characters' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\App [x64]","action":"Set","values":[{"name":"V","type":"DWord","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*wildcard*"
    }

    It 'rejects a value name containing wildcard characters' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"Size[MB]","type":"DWord","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*wildcard*"
    }

    It 'rejects a value with an invalid type' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"Dword32","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*invalid type*"
    }

    It 'rejects a value with an invalid comparison operator' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":1,"comparison":"Contain"}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*invalid comparison*"
    }

    It 'rejects a Set value missing its type' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","data":1}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig -ErrorAction SilentlyContinue } | Should -Throw "*requires a 'type'*"
    }

    It 'accepts a typeless NotExists value in a Set group (value is deleted, not written)' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"Legacy","comparison":"NotExists"}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig } | Should -Not -Throw
    }

    It 'accepts a Delete value without a type' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Delete","values":[{"name":"V"}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig } | Should -Not -Throw
    }

    It 'accepts valid type and comparison' {
        '{"version":"1.0","settings":[{"scope":"Machine","path":"SOFTWARE\\X","action":"Set","values":[{"name":"V","type":"DWord","data":100,"comparison":"GreaterThanOrEqual"}]}]}' |
            Set-Content -Path $script:TmpConfig -Encoding UTF8
        { Get-Configuration -Path $script:TmpConfig } | Should -Not -Throw
    }
}

Describe 'Invoke-DetectionMode error isolation' {

    It 'marks an item non-compliant instead of aborting when a value throws during evaluation' {
        # A comparison that slipped past load-time validation makes Compare-RegistryValue's
        # [ValidateSet] throw at parameter binding. The per-path try/catch should record it
        # as a non-compliant item rather than letting it bubble up as a ConfigError.
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [PSCustomObject]@{ V = 'x' } }

        $cfg = [PSCustomObject]@{
            settings = @(
                [PSCustomObject]@{
                    scope  = 'Machine'
                    path   = 'SOFTWARE\Fake'
                    action = 'Set'
                    values = @([PSCustomObject]@{ name = 'V'; type = 'String'; data = 'x'; comparison = 'Bogus' })
                }
            )
        }

        # Call directly (not inside a Should -Not -Throw block, which runs in a child
        # scope and would discard $out): if the per-path catch regressed, the binding
        # error would propagate here and fail the test outright.
        $out = Invoke-DetectionMode -Configuration $cfg -WarningAction SilentlyContinue

        # Invoke-DetectionMode emits Info log lines to the success stream too; pick the result hashtable.
        $result = $out | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        $result.Compliant | Should -Be $false
        ($result.NonCompliantItems.Reason -join ' ') | Should -Match 'Error during detection'
    }
}

Describe 'Invoke-RollbackMode value type coercion' {
    # The transaction log is JSON: a Binary byte[] round-trips to a number array and a
    # MultiString string[] to an object array. Rollback must re-coerce before
    # Set-ItemProperty -Type Binary/MultiString (which reject the raw arrays).

    It 'restores a Binary value as [byte[]] after the JSON round-trip' {
        $tmpFile = Join-Path $env:TEMP "rce-rb-bin-$(Get-Random).json"
        @{
            ConfigIdentifier = 'bin-test'
            Transactions = @(
                @{ Path = 'HKCU:\Software\RCETest'; Name = 'Blob'; Existed = $true; Type = 'Binary'; Value = [byte[]]@(60, 0, 0, 0) }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8

        Mock Test-Path { $true }
        Mock Set-ItemProperty { }
        Mock New-Item { }
        try {
            Invoke-RollbackMode -TransactionFile $tmpFile | Out-Null
            Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Value -is [byte[]] -and $Value.Length -eq 4 }
        }
        finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }

    It 'restores a MultiString value as [string[]] after the JSON round-trip' {
        $tmpFile = Join-Path $env:TEMP "rce-rb-multi-$(Get-Random).json"
        @{
            ConfigIdentifier = 'multi-test'
            Transactions = @(
                @{ Path = 'HKCU:\Software\RCETest'; Name = 'List'; Existed = $true; Type = 'MultiString'; Value = [string[]]@('a', 'b') }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8

        Mock Test-Path { $true }
        Mock Set-ItemProperty { }
        Mock New-Item { }
        try {
            Invoke-RollbackMode -TransactionFile $tmpFile | Out-Null
            Should -Invoke Set-ItemProperty -Times 1 -ParameterFilter { $Value -is [string[]] -and $Value.Length -eq 2 }
        }
        finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-RollbackMode identifier resolution' {

    It 'reads ConfigIdentifier from the transaction log' {
        $tmpFile = Join-Path $env:TEMP "rce-rollback-id-$(Get-Random).json"
        @{
            EngineVersion    = '1.1.0'
            ConfigIdentifier = 'test-config'
            ComputerName     = 'TEST'
            Timestamp        = (Get-Date).ToString('o')
            Transactions     = @()
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8

        # Establish a known starting value so we can prove the rollback path moved it
        $script:ConfigIdentifier = 'before-rollback'

        # Defensive: rollback shouldn't actually mutate anything with empty Transactions,
        # but mock the registry cmdlets in case any path tries.
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock New-Item { }

        try {
            Invoke-RollbackMode -TransactionFile $tmpFile | Out-Null
            $script:ConfigIdentifier | Should -Be 'test-config'
        }
        finally {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to filename for transaction logs without ConfigIdentifier' {
        # Older transaction files (pre-1.1) don't have the field
        $stem = "Transaction_legacy_$(Get-Random)"
        $tmpFile = Join-Path $env:TEMP "$stem.json"
        @{
            EngineVersion = '1.0.0'
            ComputerName  = 'TEST'
            Timestamp     = (Get-Date).ToString('o')
            Transactions  = @()
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile -Encoding UTF8

        $script:ConfigIdentifier = 'before-rollback'

        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock New-Item { }

        try {
            Invoke-RollbackMode -TransactionFile $tmpFile | Out-Null
            $script:ConfigIdentifier | Should -Be $stem
        }
        finally {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ConvertFrom-RegistryExport duplicate resolution' {
    # The converter is where duplicates are manufactured: it groups by scope|path and
    # appends, so a .reg holding the same key section twice used to merge into one
    # group with the name repeated. Resolving it here - last occurrence wins, as
    # regedit does on import - is what keeps the problem out of the config entirely.

    BeforeAll {
        $script:Converter = Join-Path (Split-Path -Parent $script:EnginePath) 'ConvertFrom-RegistryExport.ps1'

        function Convert-TestReg {
            # AllowEmptyString: a mandatory [string[]] otherwise rejects the blank
            # lines that separate key sections in a .reg.
            param([Parameter(Mandatory)] [AllowEmptyString()] [string[]]$Lines)
            $reg  = Join-Path $env:TEMP "rce-dup-$(Get-Random).reg"
            $json = [System.IO.Path]::ChangeExtension($reg, '.json')
            (@('Windows Registry Editor Version 5.00', '') + $Lines) -join "`r`n" |
                Set-Content -Path $reg -Encoding UTF8
            try {
                & $script:Converter -Path $reg -OutputPath $json *> $null
                Get-Content -Path $json -Raw | ConvertFrom-Json
            }
            finally {
                Remove-Item -LiteralPath $reg, $json -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps only the last occurrence when a key section is repeated' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Enabled"=dword:00000001',
            '',
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Enabled"=dword:00000000'
        )
        $values = @($cfg.settings | ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Enabled' })
        $values.Count | Should -Be 1
        $values[0].data | Should -Be 0
    }

    It 'keeps only the last occurrence within a single key section' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Name"="first"',
            '"Name"="second"'
        )
        $values = @($cfg.settings | ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Name' })
        $values.Count | Should -Be 1
        $values[0].data | Should -Be 'second'
    }

    It 'matches repeated names case-insensitively, as the registry does' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Enabled"=dword:00000001',
            '"enabled"=dword:00000000'
        )
        $values = @($cfg.settings | ForEach-Object { $_.values })
        $values.Count | Should -Be 1
        $values[0].data | Should -Be 0
    }

    It 'lets a later deletion displace an earlier set of the same value' {
        # Set and Delete land in different setting groups but target one registry
        # value, so the loser has to be dropped across both or the engine sees a
        # write and a delete fighting over the same name.
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Gone"="x"',
            '"Gone"=-'
        )
        $setValues = @($cfg.settings | Where-Object { $_.action -ne 'Delete' } |
            ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Gone' })
        $delValues = @($cfg.settings | Where-Object { $_.action -eq 'Delete' } |
            ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Gone' })
        $setValues.Count | Should -Be 0
        $delValues.Count | Should -Be 1
    }

    It 'lets a later set displace an earlier deletion of the same value' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Back"=-',
            '"Back"="restored"'
        )
        $setValues = @($cfg.settings | Where-Object { $_.action -ne 'Delete' } |
            ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Back' })
        $delValues = @($cfg.settings | Where-Object { $_.action -eq 'Delete' } |
            ForEach-Object { $_.values } | Where-Object { $_.name -eq 'Back' })
        $setValues.Count | Should -Be 1
        $setValues[0].data | Should -Be 'restored'
        $delValues.Count | Should -Be 0
    }

    It 'leaves the same name under two different keys alone' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDupA]',
            '"Enabled"=dword:00000001',
            '',
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDupB]',
            '"Enabled"=dword:00000000'
        )
        @($cfg.settings | ForEach-Object { $_.values }).Count | Should -Be 2
    }

    It 'produces a config the engine accepts without a duplicate warning' {
        $cfg = Convert-TestReg @(
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Enabled"=dword:00000001',
            '',
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCEDup]',
            '"Enabled"=dword:00000000'
        )
        $warnings = $null
        Assert-ValidConfig -Config $cfg -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-RegistryExport default value' {
    It 'maps a .reg default value (@=) to the name (default), never an empty string' {
        $converter = Join-Path (Split-Path -Parent $script:EnginePath) 'ConvertFrom-RegistryExport.ps1'
        $reg  = Join-Path $env:TEMP "rce-conv-$(Get-Random).reg"
        $json = [System.IO.Path]::ChangeExtension($reg, '.json')
        @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\SOFTWARE\RCETest]',
            '@="defaultval"',
            '"Other"="x"'
        ) -join "`r`n" | Set-Content -Path $reg -Encoding UTF8
        try {
            & $converter -Path $reg -OutputPath $json *> $null
            $cfg = Get-Content -Path $json -Raw | ConvertFrom-Json
            $names = $cfg.settings | ForEach-Object { $_.values } | ForEach-Object { $_.name }
            $names | Should -Contain '(default)'
            $names | Should -Not -Contain ''
        }
        finally {
            Remove-Item -LiteralPath $reg, $json -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits high-bit DWord/QWord as the unsigned decimal regedit shows, not a negative' {
        # dword:ffffffff used to land in the JSON as -1, which reads like a bug and
        # led users to hand-edit the file. Both forms work; the unsigned one matches
        # what regedit displays.
        $converter = Join-Path (Split-Path -Parent $script:EnginePath) 'ConvertFrom-RegistryExport.ps1'
        $reg  = Join-Path $env:TEMP "rce-conv-$(Get-Random).reg"
        $json = [System.IO.Path]::ChangeExtension($reg, '.json')
        @(
            'Windows Registry Editor Version 5.00',
            '',
            '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hashes\SHA256]',
            '"Enabled"=dword:ffffffff',
            '"Small"=dword:00000001',
            '"Big"=hex(b):ff,ff,ff,ff,ff,ff,ff,ff'
        ) -join "`r`n" | Set-Content -Path $reg -Encoding UTF8
        try {
            & $converter -Path $reg -OutputPath $json *> $null
            $cfg = Get-Content -Path $json -Raw | ConvertFrom-Json
            $values = @($cfg.settings | ForEach-Object { $_.values })

            ($values | Where-Object { $_.name -eq 'Enabled' }).data | Should -Be 4294967295
            ($values | Where-Object { $_.name -eq 'Small' }).data   | Should -Be 1
            ($values | Where-Object { $_.name -eq 'Big' }).data     | Should -Be ([uint64]::MaxValue)

            # ...and the engine still writes the correct bit pattern from that form
            Convert-RegistryValue -Type 'DWord' -Value ($values | Where-Object { $_.name -eq 'Enabled' }).data | Should -Be (-1)
        }
        finally {
            Remove-Item -LiteralPath $reg, $json -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Write-Log identifier tagging' {

    It 'prepends [$script:ConfigIdentifier] to emitted output' {
        # Both sinks (console + Event Log) emit the same $taggedMessage variable,
        # so the console-stream assertion proves the tagging logic ran. Console
        # output works regardless of elevation; the elevated-only Event Log
        # assertion is in the next test.
        $script:ConfigIdentifier = 'pester-tag-test'
        $captured = Write-Log -Message 'something happened' -Level Info
        $captured | Should -Match '\[pester-tag-test\] something happened'
    }

    It 'appends tagged message and level to the file log' {
        $tmpFile = Join-Path $env:TEMP "rce-pester-$(Get-Random).log"
        $script:LogFilePath = $tmpFile
        $script:ConfigIdentifier = 'file-sink-tag'
        try {
            Write-Log -Message 'file sink line' -Level Warning -WarningAction SilentlyContinue | Out-Null
            $content = Get-Content -Path $tmpFile -Raw
            $content | Should -Match '\[WARN\]'
            $content | Should -Match '\[file-sink-tag\] file sink line'
            # ISO 8601 UTC timestamp at the start
            $content | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'
        }
        finally {
            if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force }
        }
    }

    It 'tags Event Log entries when running elevated' -Skip:(-not (
        [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $script:ConfigIdentifier = 'evt-tag-test'
        $script:CreateEventLog = $true  # bypass the script-param reference

        # Pretend the source already exists so we don't call New-EventLog
        Mock Write-EventLog { }

        # Override the param-scope $CreateEventLog by setting it as a local var
        # in the test scope; Write-Log resolves $CreateEventLog dynamically.
        $CreateEventLog = $true
        Write-Log -Message 'evt body' -Level Info | Out-Null

        Should -Invoke Write-EventLog -Times 1 -ParameterFilter {
            $Message -match '\[evt-tag-test\] evt body'
        }
    }
}

Describe 'Script sources are ASCII-only' {
    # Windows PowerShell 5.1 parses a BOM-less .ps1 as Windows-1252, so a non-ASCII
    # literal is mangled at parse time - before any -Encoding flag can help. An
    # em-dash in New-IntunePackage.ps1's header strings shipped as "a<euro>" in every
    # generated package for exactly this reason. The repo convention is BOM-less
    # UTF-8 (see PSScriptAnalyzerSettings.psd1), so the sources stay ASCII instead.

    It 'contains no non-ASCII characters in <Name>' -ForEach @(
        @{ Name = 'Invoke-RegistryConfigEngine.ps1' }
        @{ Name = 'New-IntunePackage.ps1' }
        @{ Name = 'ConvertFrom-RegistryExport.ps1' }
    ) {
        $path = Join-Path (Split-Path -Parent $script:EnginePath) $Name
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

        $offenders = [regex]::Matches($text, '[^\x00-\x7F]') |
            ForEach-Object { 'U+{0:X4}' -f [int][char]$_.Value } |
            Select-Object -Unique

        $offenders -join ', ' | Should -BeExactly '' -Because "$Name must stay ASCII; use - for an em-dash, -> for an arrow, ... for an ellipsis"
    }
}
