# Pester 5 tests for Invoke-RegistryConfigEngine.ps1
# Run with: Invoke-Pester -Path .\tests
#
# The engine is dot-sourced under the dot-source guard, so only its functions
# are loaded — no main execution. This requires Pester 5+.

BeforeAll {
    $script:EnginePath = Join-Path $PSScriptRoot '..' 'Invoke-RegistryConfigEngine.ps1' | Resolve-Path
    . $script:EnginePath
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
