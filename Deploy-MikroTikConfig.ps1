[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RouterHost,

    [string]$User = "admin",

    [ValidateRange(1, 65535)]
    [int]$Port = 22,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$IdentityFile,

    [string]$RemoteFileName,

    [switch]$Apply,

    [switch]$SkipDryRun,

    [switch]$KeepRemoteFile,

    [switch]$BatchMode,

    [switch]$AllowPlaceholderSecrets
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $Command @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($output) {
            $output | ForEach-Object { Write-Host $_ }
        }
    }
    else {
        & $Command @Arguments
        $exitCode = $LASTEXITCODE
        $output = @()
    }

    if ($exitCode -ne 0) {
        throw "$Command failed with exit code $exitCode."
    }

    return @($output)
}

function Get-SshCommonArguments {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("-p")
    $arguments.Add([string]$Port)

    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $arguments.Add("-i")
        $arguments.Add((Resolve-Path -LiteralPath $IdentityFile).Path)
        $arguments.Add("-o")
        $arguments.Add("IdentitiesOnly=yes")
    }

    if ($BatchMode) {
        $arguments.Add("-o")
        $arguments.Add("BatchMode=yes")
    }

    return ,$arguments
}

function Get-ScpCommonArguments {
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("-P")
    $arguments.Add([string]$Port)

    if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
        $arguments.Add("-i")
        $arguments.Add((Resolve-Path -LiteralPath $IdentityFile).Path)
        $arguments.Add("-o")
        $arguments.Add("IdentitiesOnly=yes")
    }

    if ($BatchMode) {
        $arguments.Add("-o")
        $arguments.Add("BatchMode=yes")
    }

    return ,$arguments
}

function Invoke-RouterCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RouterCommand
    )

    $arguments = Get-SshCommonArguments
    $arguments.Add("$User@$RouterHost")
    $arguments.Add($RouterCommand)
    return Invoke-ExternalCommand -Command "ssh.exe" -Arguments $arguments.ToArray() -CaptureOutput
}

foreach ($requiredCommand in @("ssh.exe", "scp.exe")) {
    if ($null -eq (Get-Command $requiredCommand -ErrorAction SilentlyContinue)) {
        throw "$requiredCommand was not found. Install the Windows OpenSSH Client feature."
    }
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
if ([System.IO.Path]::GetExtension($resolvedConfigPath) -ne ".json") {
    throw "ConfigPath must point to a JSON configuration consumed by Generate-MikroTikConfig.ps1."
}

if ([string]::IsNullOrWhiteSpace($RemoteFileName)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $RemoteFileName = "git-deploy-$timestamp.rsc"
}

if ($RemoteFileName -notmatch '^[A-Za-z0-9_.-]+\.rsc$') {
    throw "RemoteFileName must contain only letters, digits, dot, underscore, dash and end in .rsc."
}

$generator = Join-Path $PSScriptRoot "Generate-MikroTikConfig.ps1"
if (-not (Test-Path -LiteralPath $generator)) {
    throw "Generator not found: $generator"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $tempRoot ("mikrotik-deploy-" + [guid]::NewGuid().ToString("N")))
)
if (-not $tempDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary deployment path escaped the system temp directory."
}

$tempRscPath = Join-Path $tempDirectory $RemoteFileName
[System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

$remoteUploaded = $false

try {
    Write-Host "Generating RouterOS configuration..."
    & $generator -ConfigPath $resolvedConfigPath -OutputPath $tempRscPath

    $generatedContent = Get-Content -LiteralPath $tempRscPath -Raw
    if (-not $AllowPlaceholderSecrets -and $generatedContent.Contains("CHANGE-ME-")) {
        throw "Placeholder secrets are present. Edit the local JSON or pass -AllowPlaceholderSecrets only for a lab."
    }

    Write-Host "Testing SSH connectivity to $User@$RouterHost..."
    [void](Invoke-RouterCommand -RouterCommand "/system identity print")

    Write-Host "Uploading $RemoteFileName..."
    $scpArguments = Get-ScpCommonArguments
    $scpArguments.Add($tempRscPath)
    $scpArguments.Add("${User}@${RouterHost}:/$RemoteFileName")
    [void](Invoke-ExternalCommand -Command "scp.exe" -Arguments $scpArguments.ToArray())
    $remoteUploaded = $true

    if (-not $SkipDryRun) {
        Write-Host "Running RouterOS import dry-run..."
        [void](Invoke-RouterCommand -RouterCommand "/import file-name=$RemoteFileName verbose=yes dry-run=yes")
        Write-Host "Dry-run completed successfully."
    }

    if ($Apply) {
        if ($SkipDryRun) {
            Write-Warning "Applying without dry-run because -SkipDryRun was specified."
        }

        Write-Host "Applying $RemoteFileName to $RouterHost..."
        [void](Invoke-RouterCommand -RouterCommand "/import file-name=$RemoteFileName verbose=yes")
        Write-Host "RouterOS import completed."
    }
    else {
        Write-Host "No changes were applied. Re-run with -Apply after reviewing the dry-run."
    }
}
finally {
    if ($remoteUploaded -and -not $KeepRemoteFile) {
        try {
            Write-Host "Removing remote deployment file..."
            [void](Invoke-RouterCommand -RouterCommand "/file remove [find where name=$RemoteFileName]")
        }
        catch {
            Write-Warning "Could not remove '$RemoteFileName' from the router: $($_.Exception.Message)"
        }
    }

    if (
        $tempDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $tempDirectory)
    ) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
