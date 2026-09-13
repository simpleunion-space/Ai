#Requires -Version 5.1
<#
.SYNOPSIS
Resolves current installer URLs and writes software.yaml.

.DESCRIPTION
This script does not install software. It queries official vendor URLs/APIs,
applies the architecture policy, and writes a generated YAML manifest that
install.ps1 can consume without external PowerShell modules. When a vendor does
not publish a usable SHA-256, the installer downloaded to calculate it is kept
in the same cache layout used by install.ps1.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = '',

    [string]$DownloadRoot = '',

    [switch]$IncludeBothAppArchitectures,

    [string]$LogPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($script:ScriptRoot)) {
    $script:ScriptRoot = Get-Location
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $script:ScriptRoot 'software.yaml'
}
if ([string]::IsNullOrWhiteSpace($DownloadRoot)) {
    $DownloadRoot = Join-Path $script:ScriptRoot '.download'
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Join-Path $script:ScriptRoot '.logs') ("resolve-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

$script:Is64BitOS = [Environment]::Is64BitOperatingSystem
$script:NativeArch = if ($script:Is64BitOS) { 'x64' } else { 'x86' }
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell software resolve'
$script:Results = New-Object System.Collections.Generic.List[object]

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

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level,

        [string]$Message
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'OK' { 'Green' }
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
        [ValidateSet('Resolved', 'Warning', 'Failed')]
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

function Invoke-WebText {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 60
    )

    Write-Log -Level INFO -Message "Fetching $Uri"
    $params = Get-WebRequestCommonParams -Uri $Uri
    $params['TimeoutSec'] = $TimeoutSec
    $response = Invoke-WebRequest @params
    return [string]$response.Content
}

function Invoke-Json {
    param([string]$Uri)

    Write-Log -Level INFO -Message "Fetching JSON $Uri"
    $params = @{
        Uri         = $Uri
        Headers     = @{ 'User-Agent' = $script:UserAgent }
        ErrorAction = 'Stop'
        TimeoutSec  = 90
    }
    return Invoke-RestMethod @params
}

function Test-Url {
    param([string]$Url)

    try {
        $params = Get-WebRequestCommonParams -Uri $Url
        $params['Method'] = 'Head'
        $params['MaximumRedirection'] = 10
        $params['TimeoutSec'] = 15
        [void](Invoke-WebRequest @params)
        return $true
    }
    catch {
        Write-Log -Level WARN -Message "URL check failed: $Url ($($_.Exception.Message))"
        return $false
    }
}

function Get-GitHubReleaseHashesSha256 {
    param([string]$Uri)

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $params = Get-WebRequestCommonParams -Uri $Uri
        $params['OutFile'] = $tempFile
        Invoke-WebRequest @params
        $bytes = [System.IO.File]::ReadAllBytes($tempFile)
        # GitHub serves PowerShell/PowerShell's hashes.sha256 release asset
        # as UTF-16LE with a BOM (confirmed 2026-09-10) - decode explicitly
        # rather than relying on Invoke-WebRequest's own text-encoding
        # detection, which is not consistent across Windows PowerShell 5.1
        # vs PowerShell 7+. Falls back to UTF-8 if no BOM is present, in
        # case the asset's encoding ever changes.
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PropertyValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-FlatArray {
    param([object]$Value)

    $items = @()
    if ($null -eq $Value) {
        return $items
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($item -is [System.Array]) {
                foreach ($nested in $item) {
                    $items += $nested
                }
            }
            else {
                $items += $item
            }
        }
    }
    else {
        $items += $Value
    }

    return $items
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

function New-SoftwareId {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Arch
    )

    $raw = "$Name-$Version-$Arch".ToLowerInvariant()
    return (($raw -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Resolve-CompanyName {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Company = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Company)) {
        return $Company
    }

    switch -Regex ($Name) {
        '^(Microsoft Visual C\+\+ Redistributable|\.NET SDK|\.NET Desktop Runtime|PowerShell)' { return 'Microsoft' }
        '^Eclipse Temurin' { return 'Eclipse Adoptium' }
        '^7-Zip$' { return '7-Zip' }
        '^PDF24 Creator$' { return 'PDF24' }
        '^Adobe Acrobat Reader$' { return 'Adobe' }
        '^OpenVPN Connect$' { return 'OpenVPN' }
        '^OpenConnect GUI$' { return 'OpenConnect' }
        '^WireGuard$' { return 'WireGuard' }
    }

    switch -Regex ($Source) {
        '^Microsoft$|^\.NET releases-index$|^https://api\.github\.com/repos/PowerShell/PowerShell' { return 'Microsoft' }
        '^Adoptium API$' { return 'Eclipse Adoptium' }
        '^7-Zip' { return '7-Zip' }
        '^PDF24' { return 'PDF24' }
        '^Adobe|adobe\.com' { return 'Adobe' }
        '^OpenVPN' { return 'OpenVPN' }
        '^OpenConnect|openconnect' { return 'OpenConnect' }
        '^WireGuard' { return 'WireGuard' }
    }

    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        return $Source
    }

    return $Name
}

function Get-InstallerCachePath {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Url,
        [string]$FileName = '',
        [string]$Source = '',
        [string]$Company = ''
    )

    $package = [pscustomobject]@{
        company   = Resolve-CompanyName -Name $Name -Source $Source -Company $Company
        name      = $Name
        version   = $Version
        url       = $Url
        file_name = Get-FileNameFromUrl -Url $Url -Fallback $FileName
    }

    return Get-PackageDownloadPath -Package $package
}

function Get-Sha256FromDownload {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$TimeoutSec = 180
    )

    $tempFile = ''
    $backupFile = ''
    try {
        if ([string]::IsNullOrWhiteSpace($Destination)) {
            throw 'Checksum download destination is required.'
        }

        $parent = Split-Path -Parent $Destination
        if ([string]::IsNullOrWhiteSpace($parent)) {
            throw "Checksum download destination has no parent directory: $Destination"
        }
        New-Item -ItemType Directory -Force -Path $parent | Out-Null

        # Resolver runs always fetch the current URL rather than trusting an
        # old cache entry. Keep the temporary file beside the cache target so
        # a successful replacement cannot cross volumes. The existing cache
        # file stays untouched until both the download and SHA-256 calculation
        # succeed.
        $tempFile = Join-Path $parent ('.{0}.{1}.partial' -f (Split-Path -Leaf $Destination), [guid]::NewGuid().ToString('N'))
        $params = Get-WebRequestCommonParams -Uri $Uri
        $params['TimeoutSec'] = $TimeoutSec
        $params['OutFile'] = $tempFile
        Write-Log -Level INFO -Message "Downloading to compute checksum: $Uri"
        Invoke-WebRequest @params

        $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempFile).Hash.ToLowerInvariant()
        if (Test-Path -LiteralPath $Destination) {
            $backupFile = Join-Path $parent ('.{0}.{1}.backup' -f (Split-Path -Leaf $Destination), [guid]::NewGuid().ToString('N'))
            [System.IO.File]::Replace($tempFile, $Destination, $backupFile)
        }
        else {
            [System.IO.File]::Move($tempFile, $Destination)
        }
        $tempFile = ''

        Write-Log -Level OK -Message "Cached checksum source at $Destination"
        return $sha256
    }
    catch {
        Write-Log -Level WARN -Message "Could not compute checksum for ${Uri}: $($_.Exception.Message)"
        return ''
    }
    finally {
        if ($tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if ($backupFile) {
            Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-Package {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Arch,
        [string]$Url,
        [ValidateSet('Runtime', 'Application')]
        [string]$Category,
        [string]$InstallerType,
        [string]$InstallArgs = '',
        [string]$FileName = '',
        [string]$ExpectedSha256 = '',
        [string]$Source = '',
        [string]$Company = '',
        [string]$Warning = '',
        [bool]$Install = $true
    )

    return [pscustomobject]@{
        id              = New-SoftwareId -Name $Name -Version $Version -Arch $Arch
        company         = Resolve-CompanyName -Name $Name -Source $Source -Company $Company
        name            = $Name
        version         = $Version
        arch            = $Arch
        category        = $Category
        installer_type  = $InstallerType
        url             = $Url
        file_name       = (Get-FileNameFromUrl -Url $Url -Fallback $FileName)
        install_args    = $InstallArgs
        expected_sha256 = $ExpectedSha256
        source          = $Source
        install         = $Install
        warning         = $Warning
    }
}

function New-WarningPackage {
    param(
        [string]$Name,
        [string]$Version,
        [string]$Arch,
        [ValidateSet('Runtime', 'Application')]
        [string]$Category,
        [string]$Warning,
        [string]$Source = '',
        [string]$Company = ''
    )

    return New-Package -Name $Name -Version $Version -Arch $Arch -Url '' -Category $Category -InstallerType '' -InstallArgs '' -FileName '' -ExpectedSha256 '' -Source $Source -Company $Company -Warning $Warning -Install $false
}

function Join-WarningText {
    param(
        [string]$Existing,
        [string]$New
    )

    if ([string]::IsNullOrWhiteSpace($Existing)) {
        return $New
    }

    if ([string]::IsNullOrWhiteSpace($New)) {
        return $Existing
    }

    return "$Existing $New"
}

function Apply-InstallPolicy {
    param([object[]]$Packages)

    foreach ($package in $Packages) {
        if ($package.arch -eq 'x64' -and -not $script:Is64BitOS) {
            $package.install = $false
            $package.warning = Join-WarningText -Existing $package.warning -New 'Skipped because x64 packages cannot be installed on a 32-bit OS.'
            continue
        }

        if ($package.category -eq 'Application' -and -not $IncludeBothAppArchitectures -and $package.arch -and $package.arch -ne $script:NativeArch) {
            $package.install = $false
            $package.warning = Join-WarningText -Existing $package.warning -New "Skipped by application architecture policy. Native OS architecture is $script:NativeArch. Use -IncludeBothAppArchitectures to mark both app architectures for installation."
        }
    }

    return $Packages
}

function Select-DotNetFile {
    param(
        [object[]]$Files,
        [string]$Rid
    )

    return @($Files | Where-Object {
        $_.rid -eq $Rid -and $_.url -and $_.name -match '\.exe$'
    } | Select-Object -First 1)
}

function Resolve-VcRedistPackages {
    $packages = @()
    $legacyWarning = 'Legacy VC++ 2008/2010/2012/2013 redistributable is unsupported by Microsoft; included because it was requested.'
    # Microsoft does not publish an official checksum for any of these -
    # the 8 legacy entries below sit at permanently fixed, versioned URLs
    # (GUID-keyed download.microsoft.com paths, or a specific aka.ms alias
    # tied to one exact release, never updated in place) so their hash is
    # hardcoded once (computed 2026-09-10 from a direct download of each
    # exact URL) rather than re-downloaded on every resolve.ps1 run. The
    # two "v14 latest" entries are a genuinely rolling alias instead
    # (aka.ms/vc14/... is Microsoft's actual "whatever is current" link,
    # confirmed to be updated in place over time) - those two are hashed
    # fresh below instead of hardcoded, since a hardcoded value here would
    # silently go stale the next time Microsoft ships an update through it.
    $staticHashes = @{
        'vc2008_sp1_mfc_x86.exe'    = '8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92'
        'vc2008_sp1_mfc_x64.exe'    = 'c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654'
        'vc2010_sp1_mfc_x86.exe'    = '99dce3c841cc6028560830f7866c9ce2928c98cf3256892ef8e6cf755147b0d8'
        'vc2010_sp1_mfc_x64.exe'    = 'f3b7a76d84d23f91957aa18456a14b4e90609e4ce8194c5653384ed38dada6f3'
        'vc2012_update4_x86.exe'    = 'b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386'
        'vc2012_update4_x64.exe'    = '681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064'
        'vc2013_12.0.40664_x86.exe' = '53b605d1100ab0a88b867447bbf9274b5938125024ba01f5105a9e178a3dcdbd'
        'vc2013_12.0.40664_x64.exe' = 'a4bba7701e355ae29c403431f871a537897c363e215cafe706615e270984f17c'
    }
    $staticProvenance = ' SHA256 computed 2026-09-10 from a direct download of this exact URL (Microsoft does not publish an official checksum for this file).'

    $definitions = @(
        @{ Version = '2008 SP1 MFC Security Update'; Arch = 'x86'; Url = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe'; FileName = 'vc2008_sp1_mfc_x86.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2008 SP1 MFC Security Update'; Arch = 'x64'; Url = 'https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe'; FileName = 'vc2008_sp1_mfc_x64.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2010 SP1 MFC Security Update'; Arch = 'x86'; Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe'; FileName = 'vc2010_sp1_mfc_x86.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2010 SP1 MFC Security Update'; Arch = 'x64'; Url = 'https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe'; FileName = 'vc2010_sp1_mfc_x64.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2012 Update 4'; Arch = 'x86'; Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe'; FileName = 'vc2012_update4_x86.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2012 Update 4'; Arch = 'x64'; Url = 'https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe'; FileName = 'vc2012_update4_x64.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2013 12.0.40664.0'; Arch = 'x86'; Url = 'https://aka.ms/highdpimfc2013x86enu'; FileName = 'vc2013_12.0.40664_x86.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = '2013 12.0.40664.0'; Arch = 'x64'; Url = 'https://aka.ms/highdpimfc2013x64enu'; FileName = 'vc2013_12.0.40664_x64.exe'; Args = '/q /norestart'; Warning = $legacyWarning; Rolling = $false },
        @{ Version = 'v14 latest'; Arch = 'x86'; Url = 'https://aka.ms/vc14/vc_redist.x86.exe'; FileName = 'vc14_latest_x86.exe'; Args = '/install /quiet /norestart'; Warning = ''; Rolling = $true },
        @{ Version = 'v14 latest'; Arch = 'x64'; Url = 'https://aka.ms/vc14/vc_redist.x64.exe'; FileName = 'vc14_latest_x64.exe'; Args = '/install /quiet /norestart'; Warning = ''; Rolling = $true }
    )

    foreach ($definition in $definitions) {
        $sha = ''
        $warning = $definition.Warning
        if ($definition.Rolling) {
            $sha = Get-Sha256FromDownload -Uri $definition.Url -Destination (Get-InstallerCachePath -Name 'Microsoft Visual C++ Redistributable' -Version $definition.Version -Url $definition.Url -FileName $definition.FileName -Source 'Microsoft')
            if ($sha) {
                $warning = 'SHA256 computed from a direct download of this exact URL at resolve time (Microsoft does not publish an official checksum, and this alias is updated in place, so unlike the legacy entries above this is re-hashed on every run rather than hardcoded).'
            }
        }
        else {
            $sha = $staticHashes[$definition.FileName]
            if ($sha) {
                $warning = "$($definition.Warning)$staticProvenance".Trim()
            }
        }

        $packages += New-Package -Name 'Microsoft Visual C++ Redistributable' -Version $definition.Version -Arch $definition.Arch -Url $definition.Url -Category Runtime -InstallerType exe -InstallArgs $definition.Args -FileName $definition.FileName -Source 'Microsoft' -Warning $warning -ExpectedSha256 $sha
    }

    return $packages
}

function Resolve-DotNetPackages {
    $packages = @()
    $channels = @('5.0', '6.0', '7.0', '8.0', '9.0', '10.0')
    $rids = @{ x86 = 'win-x86'; x64 = 'win-x64' }
    $indexUrl = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json'
    $index = Invoke-Json -Uri $indexUrl

    foreach ($channel in $channels) {
        $channelEntry = @($index.'releases-index' | Where-Object { $_.'channel-version' -eq $channel } | Select-Object -First 1)
        if (-not $channelEntry) {
            $message = "No .NET releases-index entry for channel $channel."
            Write-Log -Level WARN -Message $message
            $packages += New-WarningPackage -Name ".NET $channel" -Version $channel -Arch '' -Category Runtime -Warning $message -Source '.NET releases-index'
            continue
        }

        $channelWarning = ''
        if ($channelEntry.'support-phase' -eq 'eol') {
            $channelWarning = ".NET $channel is EOL (EOL date: $($channelEntry.'eol-date')). Installing because it was requested."
            Write-Log -Level WARN -Message $channelWarning
        }

        $releaseData = Invoke-Json -Uri $channelEntry.'releases.json'
        $release = @($releaseData.releases | Where-Object { $_.'release-version' -eq $channelEntry.'latest-release' } | Select-Object -First 1)
        if (-not $release) {
            Write-Log -Level WARN -Message "No release entry matching latest-release ($($channelEntry.'latest-release')) for channel $channel; falling back to the first listed release."
            $release = @($releaseData.releases | Select-Object -First 1)
        }

        $sdk = @($release.sdks | Where-Object { $_.version -eq $channelEntry.'latest-sdk' } | Select-Object -First 1)
        if (-not $sdk) {
            $sdk = @($release.sdks | Select-Object -First 1)
        }

        foreach ($arch in @('x86', 'x64')) {
            $rid = $rids[$arch]

            if ($sdk -and $sdk.files) {
                $sdkFile = Select-DotNetFile -Files $sdk.files -Rid $rid
                if ($sdkFile) {
                    # $sdkFile.hash from releases.json is SHA-512 (128 hex
                    # chars), not SHA-256 - install.ps1's Test-FileSha256
                    # expects the latter, so that field can't be used here
                    # directly. Hash the download ourselves instead, same
                    # as every other resolver with no usable vendor SHA256.
                    $sdkSha = Get-Sha256FromDownload -Uri $sdkFile.url -Destination (Get-InstallerCachePath -Name ".NET SDK $channel" -Version $sdk.version -Url $sdkFile.url -Source '.NET releases-index')
                    $sdkWarning = if ($sdkSha) { "$channelWarning SHA256 computed from a direct download of this exact URL at resolve time (releases-index.json only publishes a SHA-512 hash, not SHA-256).".Trim() } else { $channelWarning }
                    $packages += New-Package -Name ".NET SDK $channel" -Version $sdk.version -Arch $arch -Url $sdkFile.url -Category Runtime -InstallerType exe -InstallArgs '/install /quiet /norestart' -ExpectedSha256 $sdkSha -Source '.NET releases-index' -Warning $sdkWarning
                }
                else {
                    $message = "No .NET SDK installer found for $channel $rid."
                    Write-Log -Level WARN -Message $message
                    $packages += New-WarningPackage -Name ".NET SDK $channel" -Version $channelEntry.'latest-sdk' -Arch $arch -Category Runtime -Warning $message -Source $channelEntry.'releases.json'
                }
            }
            else {
                $message = "No .NET SDK metadata found for channel $channel."
                Write-Log -Level WARN -Message $message
                $packages += New-WarningPackage -Name ".NET SDK $channel" -Version $channelEntry.'latest-sdk' -Arch $arch -Category Runtime -Warning $message -Source $channelEntry.'releases.json'
            }

            if ($release.windowsdesktop -and $release.windowsdesktop.files) {
                $desktopFile = Select-DotNetFile -Files $release.windowsdesktop.files -Rid $rid
                if ($desktopFile) {
                    # Same reasoning as the SDK above - releases.json's
                    # .hash field is SHA-512, not the SHA-256 install.ps1
                    # expects.
                    $desktopSha = Get-Sha256FromDownload -Uri $desktopFile.url -Destination (Get-InstallerCachePath -Name ".NET Desktop Runtime $channel" -Version $release.windowsdesktop.version -Url $desktopFile.url -Source '.NET releases-index')
                    $desktopWarning = if ($desktopSha) { "$channelWarning SHA256 computed from a direct download of this exact URL at resolve time (releases-index.json only publishes a SHA-512 hash, not SHA-256).".Trim() } else { $channelWarning }
                    $packages += New-Package -Name ".NET Desktop Runtime $channel" -Version $release.windowsdesktop.version -Arch $arch -Url $desktopFile.url -Category Runtime -InstallerType exe -InstallArgs '/install /quiet /norestart' -ExpectedSha256 $desktopSha -Source '.NET releases-index' -Warning $desktopWarning
                }
                else {
                    $message = "No .NET Desktop Runtime installer found for $channel $rid."
                    Write-Log -Level WARN -Message $message
                    $packages += New-WarningPackage -Name ".NET Desktop Runtime $channel" -Version $channelEntry.'latest-runtime' -Arch $arch -Category Runtime -Warning $message -Source $channelEntry.'releases.json'
                }
            }
            else {
                $message = "No .NET Desktop Runtime metadata found for channel $channel."
                Write-Log -Level WARN -Message $message
                $packages += New-WarningPackage -Name ".NET Desktop Runtime $channel" -Version $channelEntry.'latest-runtime' -Arch $arch -Category Runtime -Warning $message -Source $channelEntry.'releases.json'
            }
        }
    }

    return $packages
}

function Resolve-TemurinPackages {
    $packages = @()
    $majors = @(8, 11, 17, 21, 25)
    $imageTypes = @('jdk', 'jre')
    $archCandidates = @{
        x64 = @('x64')
        x86 = @('x32', 'x86')
    }

    foreach ($major in $majors) {
        foreach ($imageType in $imageTypes) {
            foreach ($arch in @('x86', 'x64')) {
                $assets = @()
                $lastError = $null

                foreach ($apiArch in $archCandidates[$arch]) {
                    $uri = "https://api.adoptium.net/v3/assets/latest/$major/hotspot?architecture=$apiArch&heap_size=normal&image_type=$imageType&jvm_impl=hotspot&os=windows&vendor=eclipse"
                    try {
                        $assets = @(ConvertTo-FlatArray -Value (Invoke-Json -Uri $uri))
                        if ($assets.Count -gt 0) {
                            break
                        }
                    }
                    catch {
                        $lastError = $_.Exception.Message
                    }
                }

                if ($assets.Count -eq 0) {
                    $message = "No Temurin $major $imageType installer found for $arch."
                    if ($lastError) {
                        $message = "$message Last error: $lastError"
                    }
                    Write-Log -Level WARN -Message $message
                    $packages += New-WarningPackage -Name "Eclipse Temurin $($imageType.ToUpperInvariant()) $major" -Version "$major" -Arch $arch -Category Runtime -Warning $message -Source 'Adoptium API'
                    continue
                }

                $asset = $assets | Where-Object {
                    $binary = Get-PropertyValue -InputObject $_ -Name 'binary'
                    $installer = Get-PropertyValue -InputObject $binary -Name 'installer'
                    $link = Get-PropertyValue -InputObject $installer -Name 'link'
                    [bool]$link
                } | Select-Object -First 1

                if (-not $asset) {
                    $message = "Temurin $major $imageType $arch has no Windows installer asset."
                    Write-Log -Level WARN -Message $message
                    $packages += New-WarningPackage -Name "Eclipse Temurin $($imageType.ToUpperInvariant()) $major" -Version "$major" -Arch $arch -Category Runtime -Warning $message -Source 'Adoptium API'
                    continue
                }

                $binary = Get-PropertyValue -InputObject $asset -Name 'binary'
                $installer = Get-PropertyValue -InputObject $binary -Name 'installer'
                $versionInfo = Get-PropertyValue -InputObject $asset -Name 'version'
                $versionSemver = Get-PropertyValue -InputObject $versionInfo -Name 'semver'
                $version = if ($versionSemver) { $versionSemver } else { "$major" }
                $type = if ($installer.name -match '\.msi$') { 'msi' } else { 'exe' }
                $args = if ($type -eq 'exe') { '/quiet /norestart' } else { '' }
                $name = "Eclipse Temurin $($imageType.ToUpperInvariant()) $major"

                $packages += New-Package -Name $name -Version $version -Arch $arch -Url $installer.link -Category Runtime -InstallerType $type -InstallArgs $args -FileName $installer.name -ExpectedSha256 $installer.checksum -Source 'Adoptium API'
            }
        }
    }

    return $packages
}

function Resolve-SevenZipPackages {
    $packages = @()
    $page = 'https://www.7-zip.org/download.html'
    $html = Invoke-WebText -Uri $page
    $versionMatch = [regex]::Match($html, 'Download 7-Zip\s+([0-9.]+)')

    if (-not $versionMatch.Success) {
        throw 'Could not determine latest 7-Zip version.'
    }

    $version = $versionMatch.Groups[1].Value
    $versionCompact = $version -replace '\.', ''
    $hrefMatches = [regex]::Matches($html, 'href=["''](?<href>[^"'']*7z' + [regex]::Escape($versionCompact) + '[^"'']*?\.exe)["'']', 'IgnoreCase')
    $hrefs = @($hrefMatches | ForEach-Object { $_.Groups['href'].Value })

    foreach ($arch in @('x86', 'x64')) {
        $href = if ($arch -eq 'x64') {
            @($hrefs | Where-Object { $_ -match "7z$versionCompact-x64\.exe$" } | Select-Object -First 1)
        }
        else {
            @($hrefs | Where-Object { $_ -match "7z$versionCompact\.exe$" -and $_ -notmatch 'x64|arm64' } | Select-Object -First 1)
        }

        if (-not $href) {
            if ($arch -eq 'x64') {
                $href = "https://github.com/ip7z/7zip/releases/download/$version/7z$versionCompact-x64.exe"
            }
            else {
                $href = "https://github.com/ip7z/7zip/releases/download/$version/7z$versionCompact.exe"
            }
        }
        elseif ($href -notmatch '^https?://') {
            $href = 'https://www.7-zip.org/' + $href.TrimStart('/')
        }

        $fileName = if ($arch -eq 'x64') { "7zip-$version-x64.exe" } else { "7zip-$version-x86.exe" }
        # 7-zip.org publishes no checksums file for its own releases -
        # computed directly from this exact URL instead.
        $sha = Get-Sha256FromDownload -Uri $href -Destination (Get-InstallerCachePath -Name '7-Zip' -Version $version -Url $href -FileName $fileName -Source '7-Zip download page')
        $warning = if ($sha) { 'SHA256 computed from a direct download of this exact URL at resolve time (this release has no published checksums file).' } else { '' }
        $packages += New-Package -Name '7-Zip' -Version $version -Arch $arch -Url $href -Category Application -InstallerType exe -InstallArgs '/S' -FileName $fileName -Source '7-Zip download page' -ExpectedSha256 $sha -Warning $warning
    }

    return $packages
}

function Resolve-Pdf24Packages {
    $packages = @()
    $page = 'https://creator.pdf24.org/listVersions.php'
    $html = Invoke-WebText -Uri $page
    $versionMatch = [regex]::Match($html, 'pdf24-creator-(?<version>[0-9.]+)-x64\.msi', 'IgnoreCase')

    if (-not $versionMatch.Success) {
        throw 'Could not determine latest PDF24 Creator version.'
    }

    $version = $versionMatch.Groups['version'].Value
    foreach ($arch in @('x86', 'x64')) {
        $fileName = "pdf24-creator-$version-$arch.msi"
        $url = "https://download.pdf24.org/$fileName"
        $shaMatch = [regex]::Match($html, [regex]::Escape($fileName) + '.*?([A-Fa-f0-9]{64})', 'IgnoreCase, Singleline')
        $warning = ''
        if ($shaMatch.Success) {
            $sha = $shaMatch.Groups[1].Value.ToLowerInvariant()
        }
        else {
            # The versions page's own published checksum didn't match this
            # release (page format may have changed) - fall back to
            # hashing the download ourselves rather than silently shipping
            # an unverifiable package.
            Write-Log -Level WARN -Message "Could not find a published checksum for $fileName on the PDF24 versions page; falling back to a direct download hash."
            $sha = Get-Sha256FromDownload -Uri $url -Destination (Get-InstallerCachePath -Name 'PDF24 Creator' -Version $version -Url $url -FileName $fileName -Source 'PDF24 versions page')
            $warning = if ($sha) { 'SHA256 computed from a direct download of this exact URL at resolve time (the versions page checksum could not be matched for this release).' } else { '' }
        }
        $packages += New-Package -Name 'PDF24 Creator' -Version $version -Arch $arch -Url $url -Category Application -InstallerType msi -FileName $fileName -ExpectedSha256 $sha -Source 'PDF24 versions page' -Warning $warning
    }

    return $packages
}

function Resolve-PowerShellPackages {
    $packages = @()
    $apiUrl = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
    $release = Invoke-Json -Uri $apiUrl
    $version = ([string]$release.tag_name).TrimStart('v')

    if ([string]::IsNullOrWhiteSpace($version) -or $version -notmatch '^7\.') {
        $message = "Latest stable PowerShell release is not a PowerShell 7 release: $($release.tag_name)"
        Write-Log -Level WARN -Message $message
        $packages += New-WarningPackage -Name 'PowerShell' -Version $version -Arch '' -Category Application -Warning $message -Source $apiUrl -Company 'Microsoft'
        return $packages
    }

    # PowerShell/PowerShell publishes an official hashes.sha256 asset
    # alongside every release - fetched once per resolve, reused for both
    # architectures below, instead of downloading each MSI just to hash it.
    $hashesAsset = @($release.assets | Where-Object { $_.name -eq 'hashes.sha256' } | Select-Object -First 1)
    $hashesText = $null
    if ($hashesAsset) {
        try {
            $hashesText = Get-GitHubReleaseHashesSha256 -Uri $hashesAsset.browser_download_url
        }
        catch {
            Write-Log -Level WARN -Message "Could not fetch PowerShell hashes.sha256: $($_.Exception.Message)"
        }
    }

    foreach ($arch in @('x86', 'x64')) {
        $asset = @($release.assets | Where-Object {
            $_.name -match "^PowerShell-[^-]+-win-$arch\.msi$" -and $_.browser_download_url
        } | Select-Object -First 1)

        if (-not $asset) {
            $message = "No PowerShell $version Windows MSI asset found for $arch."
            Write-Log -Level WARN -Message $message
            $packages += New-WarningPackage -Name 'PowerShell' -Version $version -Arch $arch -Category Application -Warning $message -Source $apiUrl -Company 'Microsoft'
            continue
        }

        $sha = ''
        $warning = ''
        if ($hashesText) {
            $lineMatch = [regex]::Match($hashesText, '(?m)^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset.name) + '\s*$')
            if ($lineMatch.Success) {
                $sha = $lineMatch.Groups[1].Value.ToLowerInvariant()
                $warning = 'SHA256 from the official hashes.sha256 file published alongside this GitHub release.'
            }
        }
        if (-not $sha) {
            Write-Log -Level WARN -Message "Could not find $($asset.name) in PowerShell's hashes.sha256; falling back to a direct download+hash."
            $sha = Get-Sha256FromDownload -Uri $asset.browser_download_url -Destination (Get-InstallerCachePath -Name 'PowerShell' -Version $version -Url $asset.browser_download_url -FileName $asset.name -Source $apiUrl -Company 'Microsoft')
            if ($sha) {
                $warning = 'SHA256 computed from a direct download of this exact URL at resolve time (could not locate this file in the release''s own hashes.sha256).'
            }
        }

        $packages += New-Package -Name 'PowerShell' -Version $version -Arch $arch -Url $asset.browser_download_url -Category Application -InstallerType msi -FileName $asset.name -Source $apiUrl -Company 'Microsoft' -ExpectedSha256 $sha -Warning $warning
    }

    return $packages
}

function Resolve-AdobeReaderPackages {
    $packages = @()
    $indexUrl = 'https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html'

    try {
        $html = Invoke-WebText -Uri $indexUrl -TimeoutSec 20
    }
    catch {
        $message = "Could not fetch Adobe Reader release notes: $($_.Exception.Message)"
        Write-Log -Level WARN -Message $message
        $packages += New-WarningPackage -Name 'Adobe Acrobat Reader' -Version '' -Arch '' -Category Application -Warning $message -Source $indexUrl
        return $packages
    }

    $versionMatch = [regex]::Match($html, '([0-9]{2}\.[0-9]{3}\.[0-9]{5})\s+(?:Planned|Optional|Out of cycle)', 'IgnoreCase')
    if (-not $versionMatch.Success) {
        $message = 'Could not determine latest Adobe Reader Continuous Track version.'
        Write-Log -Level WARN -Message $message
        $packages += New-WarningPackage -Name 'Adobe Acrobat Reader' -Version '' -Arch '' -Category Application -Warning $message -Source $indexUrl
        return $packages
    }

    $version = $versionMatch.Groups[1].Value
    $compact = $version -replace '\.', ''
    $hostCandidates = @('https://ardownload2.adobe.com', 'https://ardownload3.adobe.com')
    $fileNames = @{
        x86 = "AcroRdrDC${compact}_MUI.exe"
        x64 = "AcroRdrDCx64${compact}_MUI.exe"
    }

    foreach ($arch in @('x86', 'x64')) {
        $selectedUrl = ''
        foreach ($hostName in $hostCandidates) {
            $candidate = "$hostName/pub/adobe/reader/win/AcrobatDC/$compact/$($fileNames[$arch])"
            if (Test-Url -Url $candidate) {
                $selectedUrl = $candidate
                break
            }
        }

        if (-not $selectedUrl) {
            $message = "No verified Adobe Reader full installer URL found for $version $arch. MSP updates are not used as clean installs."
            Write-Log -Level WARN -Message $message
            $packages += New-WarningPackage -Name 'Adobe Acrobat Reader' -Version $version -Arch $arch -Category Application -Warning $message -Source $indexUrl
            continue
        }

        # Adobe publishes no checksum file for these installers - computed
        # directly from the exact URL instead, same as 7-Zip/PowerShell
        # fallback/OpenVPN/OpenConnect GUI/WireGuard below.
        $sha = Get-Sha256FromDownload -Uri $selectedUrl -Destination (Get-InstallerCachePath -Name 'Adobe Acrobat Reader' -Version $version -Url $selectedUrl -FileName $fileNames[$arch] -Source 'Adobe release notes')
        $warning = if ($sha) { 'SHA256 computed from a direct download of this exact URL at resolve time (Adobe does not publish an official checksum for this file).' } else { '' }
        $packages += New-Package -Name 'Adobe Acrobat Reader' -Version $version -Arch $arch -Url $selectedUrl -Category Application -InstallerType exe -InstallArgs '/sAll /rs /rps /msi EULA_ACCEPT=YES' -FileName $fileNames[$arch] -Source 'Adobe release notes' -ExpectedSha256 $sha -Warning $warning
    }

    return $packages
}

function Resolve-OpenVpnConnectPackages {
    # OpenVPN publishes no checksums file for these "latest" aliases -
    # computed directly from each exact URL instead, fresh on every
    # resolve (this redirect target changes over time, so a hardcoded
    # value here would silently go stale).
    #
    # Known gap (confirmed 2026-09-12): openvpn.net's TLS endpoint fails
    # the handshake specifically from PowerShell's HTTP client on this
    # machine ("The SSL connection could not be established") even with
    # TLS 1.2 forced, while curl against the identical URL succeeds fine -
    # a client/server TLS-stack incompatibility, not a bug in this
    # resolver. Get-Sha256FromDownload already degrades gracefully (empty
    # hash + a logged WARN, package still produced) when this happens; on
    # an affected machine, install.ps1 will need -AllowUnverifiedChecksum
    # for this specific package until that incompatibility is resolved
    # upstream (either side).
    $rollingWarning = 'SHA256 computed from a direct download of this exact URL at resolve time (OpenVPN does not publish an official checksum for this file).'
    $x86Url = 'https://openvpn.net/downloads/openvpn-connect-v3-windows-x86.msi'
    $x64Url = 'https://openvpn.net/downloads/openvpn-connect-v3-windows.msi'
    $shaX86 = Get-Sha256FromDownload -Uri $x86Url -Destination (Get-InstallerCachePath -Name 'OpenVPN Connect' -Version 'latest' -Url $x86Url -FileName 'openvpn-connect-v3-windows-x86.msi' -Source 'OpenVPN downloads')
    $shaX64 = Get-Sha256FromDownload -Uri $x64Url -Destination (Get-InstallerCachePath -Name 'OpenVPN Connect' -Version 'latest' -Url $x64Url -FileName 'openvpn-connect-v3-windows-x64.msi' -Source 'OpenVPN downloads')
    return @(
        (New-Package -Name 'OpenVPN Connect' -Version 'latest' -Arch x86 -Url $x86Url -Category Application -InstallerType msi -FileName 'openvpn-connect-v3-windows-x86.msi' -Source 'OpenVPN downloads' -ExpectedSha256 $shaX86 -Warning $(if ($shaX86) { $rollingWarning } else { '' })),
        (New-Package -Name 'OpenVPN Connect' -Version 'latest' -Arch x64 -Url $x64Url -Category Application -InstallerType msi -FileName 'openvpn-connect-v3-windows-x64.msi' -Source 'OpenVPN downloads' -ExpectedSha256 $shaX64 -Warning $(if ($shaX64) { $rollingWarning } else { '' }))
    )
}

function Resolve-OpenConnectGuiPackages {
    $packages = @()
    $page = 'https://gui.openconnect-vpn.net/download/'
    $html = Invoke-WebText -Uri $page
    $versionMatch = [regex]::Match($html, 'Version\s+([0-9.]+)', 'IgnoreCase')

    if (-not $versionMatch.Success) {
        throw 'Could not determine latest OpenConnect GUI version.'
    }

    $version = $versionMatch.Groups[1].Value
    $urlMatch = [regex]::Match($html, 'https://www\.infradead\.org/openconnect-gui/download/openconnect-gui-[^"''<>\s]+-win64\.exe', 'IgnoreCase')
    $url = if ($urlMatch.Success) { $urlMatch.Value } else { "https://www.infradead.org/openconnect-gui/download/openconnect-gui-$version-win64.exe" }

    # OpenConnect GUI's download page publishes no checksums - computed
    # directly from this exact URL instead.
    $sha = Get-Sha256FromDownload -Uri $url -Destination (Get-InstallerCachePath -Name 'OpenConnect GUI' -Version $version -Url $url -FileName "openconnect-gui-$version-win64.exe" -Source 'OpenConnect GUI download page')
    $warning = if ($sha) { 'SHA256 computed from a direct download of this exact URL at resolve time (OpenConnect does not publish an official checksum for this file).' } else { '' }
    $packages += New-Package -Name 'OpenConnect GUI' -Version $version -Arch x64 -Url $url -Category Application -InstallerType exe -InstallArgs '/S' -FileName "openconnect-gui-$version-win64.exe" -Source 'OpenConnect GUI download page' -ExpectedSha256 $sha -Warning $warning

    $message = 'OpenConnect GUI currently publishes a win64 installer only; x86 is skipped.'
    Write-Log -Level WARN -Message $message
    $packages += New-WarningPackage -Name 'OpenConnect GUI' -Version $version -Arch x86 -Category Application -Warning $message -Source $page

    return $packages
}

function Resolve-WireGuardPackages {
    # WireGuard publishes no separate checksums file for these installers -
    # computed directly from each exact URL instead.
    $rollingWarning = 'SHA256 computed from a direct download of this exact URL at resolve time (WireGuard does not publish a separate checksum for this file).'
    $x86Url = 'https://download.wireguard.com/windows-client/wireguard-x86-1.1.msi'
    $x64Url = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.msi'
    $shaX86 = Get-Sha256FromDownload -Uri $x86Url -Destination (Get-InstallerCachePath -Name 'WireGuard' -Version '1.1 MSI' -Url $x86Url -FileName 'wireguard-x86-1.1.msi' -Source 'WireGuard downloads')
    $shaX64 = Get-Sha256FromDownload -Uri $x64Url -Destination (Get-InstallerCachePath -Name 'WireGuard' -Version '1.1 MSI' -Url $x64Url -FileName 'wireguard-amd64-1.1.msi' -Source 'WireGuard downloads')
    return @(
        (New-Package -Name 'WireGuard' -Version '1.1 MSI' -Arch x86 -Url $x86Url -Category Application -InstallerType msi -FileName 'wireguard-x86-1.1.msi' -Source 'WireGuard downloads' -ExpectedSha256 $shaX86 -Warning $(if ($shaX86) { $rollingWarning } else { '' })),
        (New-Package -Name 'WireGuard' -Version '1.1 MSI' -Arch x64 -Url $x64Url -Category Application -InstallerType msi -FileName 'wireguard-amd64-1.1.msi' -Source 'WireGuard downloads' -ExpectedSha256 $shaX64 -Warning $(if ($shaX64) { $rollingWarning } else { '' }))
    )
}

function Resolve-AllPackages {
    $all = @()
    $resolvers = @(
        'Resolve-VcRedistPackages',
        'Resolve-DotNetPackages',
        'Resolve-TemurinPackages',
        'Resolve-SevenZipPackages',
        'Resolve-Pdf24Packages',
        'Resolve-PowerShellPackages',
        'Resolve-AdobeReaderPackages',
        'Resolve-OpenVpnConnectPackages',
        'Resolve-OpenConnectGuiPackages',
        'Resolve-WireGuardPackages'
    )

    foreach ($resolver in $resolvers) {
        try {
            Write-Log -Level INFO -Message "Resolving packages with $resolver"
            $resolved = @(& $resolver)
            $all += $resolved
        }
        catch {
            $message = "$resolver failed: $($_.Exception.Message)"
            Write-Log -Level ERROR -Message $message
            $all += New-WarningPackage -Name $resolver -Version '' -Arch '' -Category Runtime -Warning $message -Source $resolver
        }
    }

    return Apply-InstallPolicy -Packages $all
}

function ConvertTo-YamlScalar {
    param([object]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return 'true'
        }
        return 'false'
    }

    $text = [string]$Value
    $text = $text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $text + '"'
}

function Write-SoftwareYaml {
    param(
        [object[]]$Packages,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Generated by resolve.ps1. install.ps1 supports this YAML subset only.') | Out-Null
    $lines.Add('metadata:') | Out-Null
    $lines.Add('  generated_at: ' + (ConvertTo-YamlScalar -Value ([DateTimeOffset]::Now.ToString('o')))) | Out-Null
    $lines.Add('  os_arch: ' + (ConvertTo-YamlScalar -Value $script:NativeArch)) | Out-Null
    $lines.Add('  include_both_app_architectures: ' + (ConvertTo-YamlScalar -Value ([bool]$IncludeBothAppArchitectures))) | Out-Null
    $policy = if ($IncludeBothAppArchitectures) { 'both-app-architectures' } else { 'native-app-architecture-only' }
    $lines.Add('  application_architecture_policy: ' + (ConvertTo-YamlScalar -Value $policy)) | Out-Null
    $lines.Add('packages:') | Out-Null

    $fields = @('company', 'name', 'version', 'arch', 'installer_type', 'url', 'file_name', 'install_args', 'expected_sha256', 'source', 'install', 'warning')
    foreach ($package in $Packages) {
        $lines.Add('  - id: ' + (ConvertTo-YamlScalar -Value $package.id)) | Out-Null
        foreach ($field in $fields) {
            $lines.Add("    ${field}: " + (ConvertTo-YamlScalar -Value $package.$field)) | Out-Null
        }
    }

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Write-Summary {
    param([object[]]$Packages)

    foreach ($package in $Packages) {
        $status = if ($package.install) { 'Resolved' } else { 'Warning' }
        $message = if ($package.warning) { $package.warning } else { $package.url }
        Add-Result -Name $package.name -Arch $package.arch -Version $package.version -Status $status -Message $message -Url $package.url
    }

    Write-Host ''
    Write-Host 'Summary' -ForegroundColor White
    Write-Host '-------' -ForegroundColor White
    $script:Results |
        Sort-Object Name, Arch, Version, Status |
        Format-Table -AutoSize Name, Arch, Version, Status, Message

    Write-Host ''
    Write-Host "Manifest: $OutputPath" -ForegroundColor Gray
    Write-Host "Download root: $DownloadRoot" -ForegroundColor Gray
    Write-Host "Log: $LogPath" -ForegroundColor Gray
}

function Initialize-Script {
    if (-not (Test-IsWindows)) {
        throw 'This script is intended for Windows only.'
    }

    Set-TlsDefaults

    $logParent = Split-Path -Parent $LogPath
    if ($logParent) {
        New-Item -ItemType Directory -Force -Path $logParent | Out-Null
    }

    Write-Log -Level INFO -Message 'Starting resolve.ps1'
    Write-Log -Level INFO -Message "Native OS architecture: $script:NativeArch"
    Write-Log -Level INFO -Message "Include both app architectures: $([bool]$IncludeBothAppArchitectures)"
    Write-Log -Level INFO -Message "Output path: $OutputPath"
    Write-Log -Level INFO -Message "Download root: $DownloadRoot"
}

try {
    Initialize-Script
    $packages = Resolve-AllPackages
    Write-SoftwareYaml -Packages $packages -Path $OutputPath
    Write-Log -Level OK -Message "Wrote $($packages.Count) package entries to $OutputPath"
    Write-Summary -Packages $packages
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    throw
}
