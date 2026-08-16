# Example Packages

These are pre-generated Intune Remediation scripts created by `New-IntunePackage.ps1`.
They're included so you can see the output format before generating your own.

## Contents

| Files | Source Config | Description |
|-------|---------------|-------------|
| `PreferIPv4-*` | `08-prefer-ipv4.json` | Simple example - configures IPv4 preference |
| `ComparisonOperators-*` | `09-comparison-operators.json` | Advanced example - demonstrates flexible detection |

## Usage in Intune

1. Go to **Devices** → **Remediations** → **Create script package**
2. Upload the `-Detect.ps1` as the detection script
3. Upload the `-Remediate.ps1` as the remediation script
4. Configure:
   - Run script in 64-bit PowerShell: **Yes**
   - Run this script using the logged-on credentials: **No**

## Generate Your Own
```powershell
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\your-config.json" -OutputPath ".\Packages" -Prefix YourConfig
```

Include EventLog logging and Verbose output:
```powershell
.\New-IntunePackage.ps1 -ConfigPath ".\Configs\your-config.json" -OutputPath ".\Packages" -Prefix AnotherConfig -CreateEventLog -Verbose
```