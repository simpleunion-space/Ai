#Requires -Version 5.1
<#
.SYNOPSIS
Downloads and installs software from software.yaml.

.DESCRIPTION
This script consumes the generated YAML subset produced by resolve.ps1.
It does not resolve versions or URLs on its own. Installers are cached in the
.download directory by default.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InputPath = '',

    [string]$DownloadRoot = '',

    [switch]$DryRun,

    [switch]$SkipSignatureCheck,

    [switch]$AllowUnverifiedChecksum,

    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) {
    $script:ScriptRoot = Get-Location
}
if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Join-Path $script:ScriptRoot 'software.yaml'
}
if ([string]::IsNullOrWhiteSpace($DownloadRoot)) {
    $DownloadRoot = Join-Path $script:ScriptRoot '.download'
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Join-Path $script:ScriptRoot '.logs') ("install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

$script:IsPreview = [bool]($DryRun -or $WhatIfPreference)
$script:Is64BitOS = [Environment]::Is64BitOperatingSystem
$script:NativeArch = if ($script:Is64BitOS) { 'x64' } else { 'x86' }
$script:SuccessExitCodes = @(0, 3010, 1641)
$script:NeedReboot = $false
$script:Results = New-Object System.Collections.Generic.List[object]
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell software install'

function Set-TlsDefaults {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Warning "Could not set TLS defaults: $($_.Exception.Message)"
    }
}

function Test-IsWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DRYRUN')]
        [string]$Level,

        [string]$Message
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'OK' { 'Green' }
        'DRYRUN' { 'Cyan' }
        default { 'Gray' }
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $LogPath -Value $line
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Arch,
        [string]$Version,
        [ValidateSet('Installed', 'DryRun', 'Skipped', 'Warning', 'Failed')]
        [string]$Status,
        [string]$Message,
        [string]$Url = ''
    )

    $script:Results.Add([pscustomobject]@{
        Name    = $Name
        Arch    = $Arch
        Version = $Version
        Status  = $Status
        Message = $Message
        Url     = $Url
    }) | Out-Null
}

function Get-WebRequestCommonParams {
    param([string]$Uri)

    $params = @{
        Uri         = $Uri
        Headers     = @{ 'User-Agent' = $script:UserAgent }
        ErrorAction = 'Stop'
        TimeoutSec  = 60
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $params['UseBasicParsing'] = $true
    }

    return $params
}

function ConvertFrom-YamlScalar {
    param([string]$Text)

    $value = $Text.Trim()
    if ($value -eq 'true') {
        return $true
    }
    if ($value -eq 'false') {
        return $false
    }
    if ($value -eq 'null') {
        return $null
    }
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $inner = $value.Substring(1, $value.Length - 2)
        $inner = $inner -replace '\\"', '"'
        $inner = $inner -replace '\\\\', '\'
        return $inner
    }
    return $value
}

function Read-SoftwareYaml {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found: $Path. Run resolve.ps1 first."
    }

    $packages = New-Object System.Collections.Generic.List[object]
    $current = $null
    $inPackages = $false

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') {
            continue
        }

        if ($line -match '^packages:\s*$') {
            $inPackages = $true
            continue
        }

        if (-not $inPackages) {
            continue
        }

        if ($line -match '^\s{2}-\s+id:\s*(.+?)\s*$') {
            if ($current) {
                $packages.Add([pscustomobject]$current) | Out-Null
            }
            $current = [ordered]@{}
            $current['id'] = ConvertFrom-YamlScalar -Text $matches[1]
            continue
        }

        if ($line -match '^\s{4}([a-z0-9_]+):\s*(.*?)\s*$') {
            if (-not $current) {
                throw "Invalid manifest: package property appeared before package id: $line"
            }
            $current[$matches[1]] = ConvertFrom-YamlScalar -Text $matches[2]
            continue
        }

        throw "Unsupported YAML line in generated manifest: $line"
    }

    if ($current) {
        $packages.Add([pscustomobject]$current) | Out-Null
    }

    return $packages.ToArray()
}

function Get-FileNameFromUrl {
    param(
        [string]$Url,
        [string]$Fallback
    )

    if ($Fallback) {
        return $Fallback
    }

    try {
        $name = [System.IO.Path]::GetFileName(([uri]$Url).AbsolutePath)
        if ($name) {
            return $name
        }
    }
    catch {
    }

    return (($Url -replace '[^\w\.-]', '_') + '.download')
}

function Get-PackageField {
    param(
        [object]$Package,
        [string]$Name,
        [string]$Default = ''
    )

    $property = $Package.PSObject.Properties[$Name]
    if ($property) {
        return [string]$property.Value
    }

    return $Default
}

function ConvertTo-SafePathSegment {
    param(
        [string]$Value,
        [string]$Fallback
    )

    $text = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value.Trim() }
    $invalidChars = -join [System.IO.Path]::GetInvalidFileNameChars()
    $invalidPattern = '[' + [regex]::Escape($invalidChars) + ']'
    $text = [regex]::Replace($text, $invalidPattern, '-')
    $text = [regex]::Replace($text, '[\x00-\x1F]', '-')
    $text = [regex]::Replace($text, '\s+', ' ')
    $text = $text.Trim().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }

    return $text
}

function Get-PackageDownloadPath {
    param([object]$Package)

    $company = Get-PackageField -Package $Package -Name 'company' -Default ''
    if ([string]::IsNullOrWhiteSpace($company)) {
        $company = Get-PackageField -Package $Package -Name 'source' -Default ''
    }

    $companySegment = ConvertTo-SafePathSegment -Value $company -Fallback 'unknown-company'
    $productSegment = ConvertTo-SafePathSegment -Value (Get-PackageField -Package $Package -Name 'name' -Default '') -Fallback 'unknown-product'
    $versionSegment = ConvertTo-SafePathSegment -Value (Get-PackageField -Package $Package -Name 'version' -Default '') -Fallback 'unknown-version'
    $fileName = Get-FileNameFromUrl -Url (Get-PackageField -Package $Package -Name 'url' -Default '') -Fallback (Get-PackageField -Package $Package -Name 'file_name' -Default '')
    $fileSegment = ConvertTo-SafePathSegment -Value $fileName -Fallback 'installer.download'

    $companyPath = Join-Path $DownloadRoot $companySegment
    $productPath = Join-Path $companyPath $productSegment
    $versionPath = Join-Path $productPath $versionSegment
    return Join-Path $versionPath $fileSegment
}

function Get-InstallCommandPreview {
    param(
        [object]$Package,
        [string]$Path
    )

    switch ($Package.installer_type) {
        'msi' { return "msiexec.exe /i `"$Path`" /qn /norestart" }
        'msp' { return "msiexec.exe /p `"$Path`" /qn /norestart" }
        default { return "`"$Path`" $($Package.install_args)" }
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination
        if ($existing.Length -gt 0) {
            Write-Log -Level INFO -Message "Using cached file $Destination"
            return
        }
    }

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Write-Log -Level INFO -Message "Downloading $Url"
    $params = Get-WebRequestCommonParams -Uri $Url
    $params['OutFile'] = $Destination
    $params['TimeoutSec'] = 3600
    Invoke-WebRequest @params
}

function Test-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedSha256,
        [object]$Package
    )

    $expected = if ($null -eq $ExpectedSha256) { '' } else { $ExpectedSha256.Trim().ToUpperInvariant() }
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected.Length -ne 64) {
        # A wrong-length value (e.g. a resolver accidentally handing off a
        # SHA-512 digest instead of SHA-256 - this happened for .NET
        # packages, see Resolve-DotNetPackages) is just as unverifiable as
        # a missing one and must fail closed the same way, not silently
        # skip verification on its own.
        if ($AllowUnverifiedChecksum) {
            Write-Log -Level WARN -Message "No usable expected_sha256 in software.yaml for $($Package.name) $($Package.arch) $($Package.version); proceeding unverified (-AllowUnverifiedChecksum)"
            return
        }
        throw "No usable expected_sha256 in software.yaml for $($Package.name) $($Package.arch) $($Package.version); refusing to install unverified. Pass -AllowUnverifiedChecksum to override."
    }

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        throw "SHA256 mismatch for $($Package.name) $($Package.arch) $($Package.version). Expected $expected, got $actual"
    }

    Write-Log -Level OK -Message "SHA256 verified for $($Package.name) $($Package.arch) $($Package.version)"
}

function Test-FileSignature {
    param(
        [string]$Path,
        [object]$Package
    )

    if ($SkipSignatureCheck) {
        Write-Log -Level WARN -Message "Signature check skipped for $($Package.name) $($Package.arch) $($Package.version)"
        return
    }

    $signature = $null
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
    }
    catch {
        $message = "Could not check signature for $($Package.name) $($Package.arch) $($Package.version): $($_.Exception.Message)"
        Write-Log -Level WARN -Message $message
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Warning -Message $message -Url $Package.url
        return
    }

    if ($signature.Status -eq 'Valid') {
        Write-Log -Level OK -Message "Signature valid for $($Package.name) $($Package.arch) $($Package.version)"
        return
    }

    # Thrown outside the try/catch above on purpose - HashMismatch means the
    # file's own bytes don't match its embedded signature (corruption or
    # tampering), unlike NotSigned/NotTrusted/UnknownError which cover
    # legitimate unsigned freeware and shouldn't hard-block. Throwing from
    # inside the try above would just be swallowed by its own catch.
    if ($signature.Status -eq 'HashMismatch') {
        throw "Authenticode signature hash mismatch for $($Package.name) $($Package.arch) $($Package.version) - the downloaded file's contents do not match its own embedded signature (possible corruption or tampering)"
    }

    $message = "Signature status for $($Package.name) $($Package.arch) $($Package.version) is $($signature.Status)"
    Write-Log -Level WARN -Message $message
    Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Warning -Message $message -Url $Package.url
}

function Install-File {
    param(
        [object]$Package,
        [string]$Path
    )

    $arguments = switch ($Package.installer_type) {
        'msi' { "/i `"$Path`" /qn /norestart" }
        'msp' { "/p `"$Path`" /qn /norestart" }
        default { $Package.install_args }
    }

    $file = if ($Package.installer_type -in @('msi', 'msp')) { 'msiexec.exe' } else { $Path }
    $preview = Get-InstallCommandPreview -Package $Package -Path $Path
    Write-Log -Level INFO -Message "Installing with: $preview"

    $process = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    $exitCode = [int]$process.ExitCode

    if ($script:SuccessExitCodes -contains $exitCode) {
        if ($exitCode -in @(3010, 1641)) {
            $script:NeedReboot = $true
        }

        Write-Log -Level OK -Message "$($Package.name) $($Package.arch) $($Package.version) installed, exit code $exitCode"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Installed -Message "Exit code $exitCode" -Url $Package.url
        return
    }

    $message = "Installer exit code $exitCode"
    Write-Log -Level WARN -Message "$($Package.name) $($Package.arch) $($Package.version): $message"
    Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Warning -Message $message -Url $Package.url
}

function Test-PackageApplicable {
    param([object]$Package)

    if (-not $Package.install) {
        $message = if ($Package.warning) { $Package.warning } else { 'install=false in software.yaml' }
        Write-Log -Level WARN -Message "$($Package.name) $($Package.arch): skipped. $message"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Skipped -Message $message -Url $Package.url
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Package.url)) {
        $message = if ($Package.warning) { $Package.warning } else { 'No download URL in software.yaml' }
        Write-Log -Level WARN -Message "$($Package.name) $($Package.arch): skipped. $message"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Skipped -Message $message -Url $Package.url
        return $false
    }

    if ($Package.arch -eq 'x64' -and -not $script:Is64BitOS) {
        $message = 'Skipped because x64 packages cannot be installed on a 32-bit OS'
        Write-Log -Level WARN -Message "$($Package.name) $($Package.arch): $message"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Skipped -Message $message -Url $Package.url
        return $false
    }

    return $true
}

function Invoke-Package {
    param([object]$Package)

    if (-not (Test-PackageApplicable -Package $Package)) {
        return
    }

    $destination = Get-PackageDownloadPath -Package $Package
    $commandPreview = Get-InstallCommandPreview -Package $Package -Path $destination

    if ($script:IsPreview) {
        Write-Log -Level DRYRUN -Message "$($Package.name) $($Package.arch) $($Package.version)"
        Write-Log -Level DRYRUN -Message "URL: $($Package.url)"
        Write-Log -Level DRYRUN -Message "Command: $commandPreview"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status DryRun -Message $commandPreview -Url $Package.url
        return
    }

    try {
        Download-File -Url $Package.url -Destination $destination
        Test-FileSha256 -Path $destination -ExpectedSha256 (Get-PackageField -Package $Package -Name 'expected_sha256' -Default '') -Package $Package
        Test-FileSignature -Path $destination -Package $Package

        if ($PSCmdlet.ShouldProcess("$($Package.name) $($Package.arch) $($Package.version)", 'Install')) {
            Install-File -Package $Package -Path $destination
        }
        else {
            Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Skipped -Message 'Installation skipped by ShouldProcess' -Url $Package.url
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-Log -Level ERROR -Message "$($Package.name) $($Package.arch) $($Package.version): $message"
        Add-Result -Name $Package.name -Arch $Package.arch -Version $Package.version -Status Failed -Message $message -Url $Package.url
    }
}

function Write-Summary {
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor White
    Write-Host '-------' -ForegroundColor White

    $script:Results |
        Sort-Object Name, Arch, Version, Status |
        Format-Table -AutoSize Name, Arch, Version, Status, Message

    Write-Host ''
    Write-Host "Manifest: $InputPath" -ForegroundColor Gray
    Write-Host "Download root: $DownloadRoot" -ForegroundColor Gray
    Write-Host "Log: $LogPath" -ForegroundColor Gray

    if ($script:NeedReboot) {
        Write-Host 'At least one installer requested a reboot.' -ForegroundColor Yellow
    }
}

function Initialize-Script {
    if (-not (Test-IsWindows)) {
        throw 'This script is intended for Windows only.'
    }

    Set-TlsDefaults

    if (-not $script:IsPreview -and -not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session, or use -DryRun/-WhatIf for a non-mutating preview.'
    }

    $logParent = Split-Path -Parent $LogPath
    if ($logParent) {
        New-Item -ItemType Directory -Force -Path $logParent | Out-Null
    }

    if (-not $script:IsPreview) {
        New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null
    }

    Write-Log -Level INFO -Message 'Starting install.ps1'
    Write-Log -Level INFO -Message "Preview mode: $script:IsPreview"
    Write-Log -Level INFO -Message "Native OS architecture: $script:NativeArch"
    Write-Log -Level INFO -Message "Manifest: $InputPath"
    Write-Log -Level INFO -Message "Download root: $DownloadRoot"
}

try {
    Initialize-Script
    $packages = Read-SoftwareYaml -Path $InputPath
    Write-Log -Level INFO -Message "Loaded $($packages.Count) package entries from $InputPath"

    foreach ($package in $packages) {
        Invoke-Package -Package $package
    }
}
catch {
    $message = $_.Exception.Message
    if ($_.InvocationInfo) {
        $message = "$message At $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    }
    if ($_.ScriptStackTrace) {
        Write-Log -Level ERROR -Message $_.ScriptStackTrace
    }
    Write-Log -Level ERROR -Message $message
    Add-Result -Name 'Script' -Arch '-' -Version '-' -Status Failed -Message $message
}
finally {
    Write-Summary

    if (-not $script:IsPreview) {
        Write-Log -Level INFO -Message "Downloaded installers are kept in $DownloadRoot for audit/retry."
    }
}
