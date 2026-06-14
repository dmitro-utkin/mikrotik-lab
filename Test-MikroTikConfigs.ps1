[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$generator = Join-Path $PSScriptRoot "Generate-MikroTikConfig.ps1"
$profiles = @(
    @{
        Config = Join-Path $PSScriptRoot "configs/gateway.example.json"
        Expected = Join-Path $PSScriptRoot "generated/gateway.rsc"
        Role = "gateway"
    },
    @{
        Config = Join-Path $PSScriptRoot "configs/ap-legacy.example.json"
        Expected = Join-Path $PSScriptRoot "generated/ap-legacy.rsc"
        Role = "access-point"
    },
    @{
        Config = Join-Path $PSScriptRoot "configs/ap-wifi.example.json"
        Expected = Join-Path $PSScriptRoot "generated/ap-wifi.rsc"
        Role = "access-point"
    }
)

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $generator,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "PowerShell parser errors: $($parseErrors.Message -join '; ')"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $tempRoot ("mikrotik-test-" + [guid]::NewGuid().ToString("N")))
)
if (-not $tempDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary test path escaped the system temp directory."
}

[System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

try {
    foreach ($profile in $profiles) {
        [void](Get-Content -LiteralPath $profile.Config -Raw | ConvertFrom-Json)

        $actualPath = Join-Path $tempDirectory ([System.IO.Path]::GetFileName($profile.Expected))
        & $generator -ConfigPath $profile.Config -OutputPath $actualPath

        $expected = Get-Content -LiteralPath $profile.Expected -Raw
        $actual = Get-Content -LiteralPath $actualPath -Raw

        if ($actual -cne $expected) {
            throw "Generated output differs from tracked file: $($profile.Expected)"
        }

        if ($actual.LastIndexOf("vlan-filtering=yes") -lt $actual.LastIndexOf("/ip service")) {
            throw "VLAN filtering is enabled too early in $($profile.Expected)"
        }

        if ($profile.Role -eq "gateway") {
            if ($actual.Contains("action=redirect")) {
                throw "Unexpected DNS redirect in gateway output."
            }

            if (-not $actual.Contains("src-address-list=LOCAL_SUBNETS dst-address-list=LOCAL_SUBNETS")) {
                throw "Gateway inter-VLAN isolation rule is missing."
            }
        }
        else {
            if (-not $actual.Contains('interface="vlan888-mgmt" comment="AP management"')) {
                throw "AP management IP is not assigned to vlan888-mgmt."
            }

            if ($actual -match 'add address="10\.11\.88\.[^"]+" interface="bridge-ap"') {
                throw "AP management IP is incorrectly assigned to the bridge."
            }
        }

        Write-Host "OK: $([System.IO.Path]::GetFileName($profile.Expected))"
    }
}
finally {
    if (
        $tempDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $tempDirectory)
    ) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}

Write-Host "All MikroTik configuration tests passed."
