<#
.SYNOPSIS
    Converts Windows Registry export (.reg) files to Registry Configuration Engine JSON format.

.DESCRIPTION
    This script parses .reg files exported from regedit.exe and converts them to the JSON
    configuration format used by Invoke-RegistryConfigEngine.ps1. This makes it easy to
    capture existing registry settings from Group Policy, manual configuration, or
    documentation and convert them to deployable Intune remediation configs.

.PARAMETER Path
    Path to the .reg file to convert.

.PARAMETER OutputPath
    Path for the output JSON file. If not specified, outputs to same location as input
    with .json extension.

.PARAMETER Scope
    Override the automatic scope detection. By default, HKLM maps to "Machine" and
    HKCU maps to "User". Use this parameter to force a specific scope for all settings.
    Valid values: Machine, User, DefaultUser

.PARAMETER DefaultAction
    The action to use for settings. Default is "Set". Use "Delete" for value deletions
    or "DeleteKey" for key deletions (automatically detected from .reg file syntax).

.EXAMPLE
    .\ConvertFrom-RegistryExport.ps1 -Path ".\exported.reg"
    Converts exported.reg to exported.json in the same directory.

.EXAMPLE
    .\ConvertFrom-RegistryExport.ps1 -Path ".\gpo-settings.reg" -OutputPath ".\config.json"
    Converts gpo-settings.reg to config.json.

.EXAMPLE
    .\ConvertFrom-RegistryExport.ps1 -Path ".\user-prefs.reg" -Scope "User"
    Forces all settings to use "User" scope regardless of registry hive.

.NOTES
    Supported .reg file formats:
    - Windows Registry Editor Version 5.00 (Unicode, Windows 2000+)
    - REGEDIT4 (ANSI, legacy)

    Supported value types:
    - REG_SZ (String)
    - REG_DWORD (DWord)
    - REG_QWORD (QWord)
    - REG_BINARY (Binary)
    - REG_EXPAND_SZ (ExpandString)
    - REG_MULTI_SZ (MultiString)
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Machine', 'User', 'DefaultUser')]
    [string]$Scope,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Set', 'Delete', 'DeleteKey')]
    [string]$DefaultAction = 'Set'
)

#region Helper Functions

function Get-ScopeFromHive {
    param([string]$HivePath)

    if ($HivePath -match '^HKEY_LOCAL_MACHINE|^HKLM') {
        return 'Machine'
    }
    elseif ($HivePath -match '^HKEY_CURRENT_USER|^HKCU') {
        return 'User'
    }
    elseif ($HivePath -match '^HKEY_USERS\\\.DEFAULT') {
        Write-Warning "HKEY_USERS\.DEFAULT is the LocalSystem account's profile, not the Default User template. Mapping to DefaultUser scope (C:\Users\Default) - use -Scope to override if that is not what you want."
        return 'DefaultUser'
    }
    elseif ($HivePath -match '^HKEY_USERS\\|^HKU\\') {
        # Per-SID export: the SID is stripped from the path, so apply the
        # settings to all user profiles.
        return 'User'
    }
    else {
        Write-Warning "Unknown hive: $HivePath - defaulting to Machine scope"
        return 'Machine'
    }
}

function Get-PathFromHive {
    param([string]$HivePath)

    # Remove the hive prefix and return the subkey path
    $path = $HivePath -replace '^HKEY_LOCAL_MACHINE\\', ''
    $path = $path -replace '^HKLM\\', ''
    $path = $path -replace '^HKEY_CURRENT_USER\\', ''
    $path = $path -replace '^HKCU\\', ''
    $path = $path -replace '^HKEY_USERS\\\.DEFAULT\\', ''
    $path = $path -replace '^HKEY_USERS\\[^\\]+\\', ''  # Strip SID for HKU paths

    return $path
}

function ConvertFrom-RegValue {
    param(
        [string]$Name,
        [string]$TypeAndData
    )

    $result = @{
        name = $Name
    }

    # Handle deletion marker
    if ($TypeAndData -eq '-') {
        # Value deletion - we'll mark this specially
        $result.delete = $true
        return $result
    }

    # Parse type and data
    switch -Regex ($TypeAndData) {
        # REG_SZ - just a quoted string
        '^"(.*)"$' {
            $result.type = 'String'
            $result.data = $Matches[1] -replace '\\\\', '\' -replace '\\"', '"'
        }

        # REG_DWORD
        '^dword:([0-9a-fA-F]{8})$' {
            $result.type = 'DWord'
            $result.data = [Convert]::ToInt32($Matches[1], 16)
        }

        # REG_QWORD
        '^hex\(b\):(.+)$' {
            $result.type = 'QWord'
            $hexBytes = $Matches[1] -split ',' | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }
            $result.data = [BitConverter]::ToInt64($hexBytes, 0)
        }

        # REG_BINARY
        '^hex:(.*)$' {
            $result.type = 'Binary'
            $hexData = $Matches[1].Trim()
            if ($hexData) {
                # Convert to comma-separated uppercase hex for readability
                $bytes = $hexData -split ',' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim().ToUpper() }
                $result.data = $bytes -join ','
            }
            else {
                $result.data = ''
            }
        }

        # REG_EXPAND_SZ (hex(2)) — empty data ("hex(2):") is a valid empty string
        '^hex\(2\):(.*)$' {
            $result.type = 'ExpandString'
            $hexPart = $Matches[1].Trim()
            if ($hexPart) {
                $hexBytes = $hexPart -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }
                # UTF-16LE encoded, null-terminated
                $result.data = [System.Text.Encoding]::Unicode.GetString($hexBytes).TrimEnd("`0")
            }
            else {
                $result.data = ''
            }
        }

        # REG_MULTI_SZ (hex(7)) — empty data ("hex(7):") is a valid empty list
        '^hex\(7\):(.*)$' {
            $result.type = 'MultiString'
            $hexPart = $Matches[1].Trim()
            if ($hexPart) {
                $hexBytes = $hexPart -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [Convert]::ToByte($_.Trim(), 16) }
                # UTF-16LE encoded, double-null terminated, values separated by null
                $decoded = [System.Text.Encoding]::Unicode.GetString($hexBytes).TrimEnd("`0")
                $result.data = @($decoded -split "`0" | Where-Object { $_ })
            }
            else {
                $result.data = @()
            }
        }

        default {
            Write-Warning "Unknown value format: $TypeAndData"
            $result.type = 'String'
            $result.data = $TypeAndData
        }
    }

    return $result
}

#endregion

#region Main Logic

# Determine output path
if (-not $OutputPath) {
    $OutputPath = [System.IO.Path]::ChangeExtension($Path, '.json')
}

Write-Host "Converting: $Path" -ForegroundColor Cyan
Write-Host "Output:     $OutputPath" -ForegroundColor Cyan

# Read the .reg file - handle both Unicode and ANSI
$content = $null
try {
    # Try UTF-16 LE (standard for "Windows Registry Editor Version 5.00")
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $content = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        # Try UTF-8 or ANSI
        $content = Get-Content -Path $Path -Raw -Encoding UTF8
    }
}
catch {
    $content = Get-Content -Path $Path -Raw
}

# Normalize line endings and split
$lines = $content -replace "`r`n", "`n" -split "`n"

# Join continuation lines (lines ending with \)
$joinedLines = @()
$buffer = ''
foreach ($line in $lines) {
    if ($line -match '\\$') {
        $buffer += $line.TrimEnd('\')
    }
    else {
        $buffer += $line
        $joinedLines += $buffer
        $buffer = ''
    }
}
if ($buffer) { $joinedLines += $buffer }

# Parse the file
$settings = @{}
$currentKey = $null
$deleteKeys = @()

foreach ($line in $joinedLines) {
    $line = $line.Trim()

    # Skip empty lines and comments
    if (-not $line -or $line.StartsWith(';')) { continue }

    # Skip header
    if ($line -match '^Windows Registry Editor|^REGEDIT4') { continue }

    # Key deletion: [-HKEY_...]
    if ($line -match '^\[-(.+)\]$') {
        $hivePath = $Matches[1]
        $deleteKeys += @{
            scope = if ($Scope) { $Scope } else { Get-ScopeFromHive $hivePath }
            path  = Get-PathFromHive $hivePath
        }
        continue
    }

    # New key: [HKEY_...]
    if ($line -match '^\[(.+)\]$') {
        $currentKey = $Matches[1]
        $keyScope = if ($Scope) { $Scope } else { Get-ScopeFromHive $currentKey }
        $keyPath = Get-PathFromHive $currentKey

        # Create unique key for grouping
        $groupKey = "$keyScope|$keyPath"
        if (-not $settings.ContainsKey($groupKey)) {
            $settings[$groupKey] = @{
                scope  = $keyScope
                path   = $keyPath
                action = $DefaultAction
                values = @()
            }
        }
        continue
    }

    # Value line: "name"=value or @=value (default)
    if ($currentKey -and $line -match '^(@|"([^"]*)")\s*=\s*(.*)$') {
        # '@' in a .reg file is the key's default value. The engine targets it via
        # the literal name '(default)' (the registry provider can't bind -Name '').
        $valueName = if ($Matches[1] -eq '@') { '(default)' } else { $Matches[2] }
        $valueData = $Matches[3]

        $keyScope = if ($Scope) { $Scope } else { Get-ScopeFromHive $currentKey }
        $keyPath = Get-PathFromHive $currentKey
        $groupKey = "$keyScope|$keyPath"

        $parsedValue = ConvertFrom-RegValue -Name $valueName -TypeAndData $valueData

        if ($parsedValue.delete) {
            # This is a value deletion - create separate setting
            $deleteKey = "$groupKey|DELETE"
            if (-not $settings.ContainsKey($deleteKey)) {
                $settings[$deleteKey] = @{
                    scope  = $keyScope
                    path   = $keyPath
                    action = 'Delete'
                    values = @()
                }
            }
            $settings[$deleteKey].values += @{
                name = $parsedValue.name
            }
        }
        else {
            $settings[$groupKey].values += @{
                name = $parsedValue.name
                type = $parsedValue.type
                data = $parsedValue.data
            }
        }
    }
}

# Build output structure
$outputSettings = @()

# Add key deletions first
foreach ($dk in $deleteKeys) {
    $outputSettings += @{
        scope  = $dk.scope
        path   = $dk.path
        action = 'DeleteKey'
    }
}

# Add value settings (filter out empty ones)
foreach ($key in $settings.Keys | Sort-Object) {
    $setting = $settings[$key]
    if ($setting.values.Count -gt 0) {
        $outputSettings += $setting
    }
}

# Create final JSON structure with metadata
$output = [ordered]@{
    '$schema'    = 'https://alttabtowork.com/schemas/registry-config-v1.json'
    version      = '1.0'
    author       = ''
    description  = "Converted from $([System.IO.Path]::GetFileName($Path))"
    created      = (Get-Date -Format 'yyyy-MM-dd')
    notes        = @(
        'Converted from .reg file - please review and adjust as needed',
        'Add descriptions to settings and values for documentation'
    )
    settings     = $outputSettings
}

# Convert to JSON and save
$json = $output | ConvertTo-Json -Depth 10

# Pretty-print with consistent formatting
$json | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host ""
Write-Host "Conversion complete!" -ForegroundColor Green
Write-Host "  Settings: $($outputSettings.Count)" -ForegroundColor Gray
Write-Host "  Values:   $(($outputSettings | ForEach-Object { $_.values.Count } | Measure-Object -Sum).Sum)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Review the generated JSON file" -ForegroundColor Gray
Write-Host "  2. Validate: .\Invoke-RegistryConfigEngine.ps1 -ConfigPath '$OutputPath' -Mode Validate" -ForegroundColor Gray
Write-Host "  3. Test:     .\Invoke-RegistryConfigEngine.ps1 -ConfigPath '$OutputPath' -Mode Detect -Verbose" -ForegroundColor Gray
Write-Host "  4. Package:  .\New-IntunePackage.ps1 -ConfigPath '$OutputPath'" -ForegroundColor Gray

#endregion
