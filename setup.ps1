#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Complete Local System Provisioning & Virtual Display Driver Setup
.DESCRIPTION
    1. Optimizes RDP rendering & TCP stack for low latency.
    2. Installs and configures MttVDD (Virtual Display Driver) at 1080p@60Hz.
    3. Configures system UI (Dark Mode) & adds Arabic keyboard layout.
    4. Deploys baseline applications via winget (e.g., VLC).
.NOTES
    Version : 2.0.1
    Requires: PowerShell 5.1+, Windows 10/Server 2019+, Admin rights
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Global Configuration ─────────────────────────────────────────────────────

$Config = @{
    DriverRepo   = 'https://github.com/itsmikethetech/Virtual-Display-Driver'
    ReleasesApi  = 'https://api.github.com/repos/itsmikethetech/Virtual-Display-Driver/releases/latest'
    InstallDir   = 'C:\VirtualDisplay'
    ResolutionW  = 1920
    ResolutionH  = 1080
    RefreshRate  = 60
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Section ([string]$Title) {
    Write-Host "`n┌── $Title" -ForegroundColor Cyan
}

function Write-Ok   ([string]$Msg) { Write-Host "│  [✓] $Msg" -ForegroundColor Green  }
function Write-Info ([string]$Msg) { Write-Host "│  [i] $Msg" -ForegroundColor Yellow }
function Write-Err  ([string]$Msg) { Write-Host "│  [!] $Msg" -ForegroundColor Red    }

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Ok "$Name = $Value"
}

# ─── 1. RDP & Performance Optimization ───────────────────────────────────────

Write-Section 'RDP Frame Rate & System Performance Setup'
Set-RegValue `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' `
    -Name 'DWMFRAMEINTERVAL' `
    -Value 15   # 15 ms ≈ 60 fps remote rendering

# ─── 2. TCP Low-Latency Tuning ────────────────────────────────────────────────

Write-Section 'TCP Low-Latency Stack Configuration'
$TcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
@{
    TcpAckFrequency = 1   # ACK on every segment
    TCPNoDelay      = 1   # Disable Nagle's algorithm
} | ForEach-Object { $_.GetEnumerator() } | ForEach-Object {
    Set-RegValue -Path $TcpParams -Name $_.Key -Value $_.Value
}

# ─── 3. UI Dark Theme Setup ───────────────────────────────────────────────────

Write-Section 'System & App Dark Theme'
$ThemePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
@{
    AppsUseLightTheme   = 0
    SystemUsesLightTheme = 0
} | ForEach-Object { $_.GetEnumerator() } | ForEach-Object {
    Set-RegValue -Path $ThemePath -Name $_.Key -Value $_.Value
}

# ─── 4. Keyboard Language Configuration ───────────────────────────────────────

Write-Section 'Keyboard Language Configuration'
try {
    $LangList = Get-WinUserLanguageList
    if ($LangList.LanguageTag -notcontains 'ar-SA') {
        $LangList.Add('ar-SA')
        Set-WinUserLanguageList -LanguageList $LangList -Force
        Write-Ok 'Arabic (ar-SA) keyboard added'
    } else {
        Write-Info 'Arabic keyboard already present — skipped'
    }
} catch {
    Write-Err "Language config failed: $_"
}

# ─── 5. Application Installation (winget) ─────────────────────────────────────

Write-Section 'Background Application Deployment'
$Apps = @(
    @{ Id = 'VideoLAN.VLC'; Name = 'VLC Media Player' }
)

foreach ($App in $Apps) {
    Write-Info "Installing $($App.Name)..."
    try {
        $result = winget install --id $App.Id --silent --accept-source-agreements --accept-package-agreements 2>&1
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
            Write-Ok "$($App.Name) ready"
        } else {
            Write-Err "$($App.Name) — winget exit code: $LASTEXITCODE"
        }
    } catch {
        Write-Err "winget execution failed: $_"
    }
}

# ─── 6. Virtual Display Driver (MttVDD) Installation ─────────────────────────

Write-Section 'Pre-flight Virtual Display System Check'
$existingDisplays = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue
if ($existingDisplays) {
    Write-Info 'Found existing display device(s):'
    $existingDisplays | ForEach-Object { Write-Info "  → $($_.FriendlyName) [$($_.Status)]" }
} else {
    Write-Info 'No physical display detected — headless mode confirmed.'
}

Write-Section 'Preparing Virtual Display Directory'
try {
    if (-not (Test-Path $Config.InstallDir)) {
        New-Item -Path $Config.InstallDir -ItemType Directory -Force | Out-Null
    }
    Write-Ok "Working directory: $($Config.InstallDir)"
} catch {
    Write-Err "Cannot create directory: $_"
    exit 1
}

Write-Section 'Downloading Virtual Display Driver (MttVDD)'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri $Config.ReleasesApi -UseBasicParsing
    $tag     = $release.tag_name
    $asset   = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1

    if (-not $asset) { throw "No ZIP asset found in release $tag" }

    $zipPath = Join-Path $Config.InstallDir "$($asset.name)"
    Write-Info "Release : $tag"
    Write-Info "Asset   : $($asset.name) ($([math]::Round($asset.size/1MB, 1)) MB)"

    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    Write-Ok "Downloaded to: $zipPath"
} catch {
    Write-Err "Download failed: $_"
    Write-Info "Manual download: $($Config.DriverRepo)/releases"
    exit 1
}

Write-Section 'Extracting Driver Package'
try {
    $extractPath = Join-Path $Config.InstallDir 'driver'
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    Write-Ok "Extracted to: $extractPath"

    $infFile = Get-ChildItem -Path $extractPath -Filter '*.inf' -Recurse | Select-Object -First 1
    if (-not $infFile) { throw 'No .inf file found in extracted package' }

    Write-Ok "INF file: $($infFile.FullName)"
} catch {
    Write-Err "Extraction failed: $_"
    exit 1
}

Write-Section 'Driver Signature & Certificate Setup'
try {
    $certFile = Get-ChildItem -Path $extractPath -Filter '*.cer' -Recurse | Select-Object -First 1
    if ($certFile) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile.FullName)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
        )
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($cert)
        $store.Close()
        Write-Ok "Certificate installed: $($cert.Subject)"
    } else {
        Write-Info 'No .cer file found — skipping cert install'
    }

    $sysFile = Get-ChildItem -Path $extractPath -Filter '*.sys' -Recurse | Select-Object -First 1
    if ($sysFile) {
        $sigResult = Get-AuthenticodeSignature -FilePath $sysFile.FullName
        if ($sigResult.Status -ne 'Valid') {
            Write-Info "Driver signature status: $($sigResult.Status) — Enabling Test Signing Mode"
            & bcdedit /set testsigning on | Out-Null
            Write-Ok 'Test Signing enabled (reboot required)'
        } else {
            Write-Ok 'Driver signature valid — Test Signing NOT required'
        }
    }
} catch {
    Write-Err "Certificate setup error: $_"
}

Write-Section 'Installing Driver via PnPUtil'
try {
    $pnpResult = & pnputil /add-driver "$($infFile.FullName)" /install 2>&1
    Write-Host ($pnpResult | Out-String) -ForegroundColor Gray

    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'Driver installed successfully'
    } elseif ($LASTEXITCODE -eq 3010) {
        Write-Info 'Driver installed — reboot required to activate'
    } else {
        throw "pnputil exit code: $LASTEXITCODE"
    }
} catch {
    Write-Err "Driver install failed: $_"
    exit 1
}

Write-Section "Configuring Virtual Display: $($Config.ResolutionW)x$($Config.ResolutionH) @ $($Config.RefreshRate)Hz"
try {
    $timeout = 30
    $elapsed = 0
    $vDisplay = $null

    while ($elapsed -lt $timeout -and -not $vDisplay) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        $vDisplay = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
                    Where-Object { $_.FriendlyName -match 'Virtual|IDD|MttVDD' }
    }

    if ($vDisplay) {
        Write-Ok "Virtual display detected: $($vDisplay.FriendlyName)"

        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class DisplayConfig {
    [DllImport("user32.dll")]
    public static extern int ChangeDisplaySettingsEx(
        string lpszDeviceName, ref DEVMODE lpDevMode,
        IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplaySettings(
        string deviceName, int modeNum, ref DEVMODE devMode);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight;
        public uint dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
        public uint dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const uint CDS_UPDATEREGISTRY = 0x01;
    public const uint DM_PELSWIDTH  = 0x80000;
    public const uint DM_PELSHEIGHT = 0x100000;
    public const uint DM_DISPLAYFREQUENCY = 0x400000;
}
'@

        $devMode = New-Object DisplayConfig+DEVMODE
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($devMode)
        [DisplayConfig]::EnumDisplaySettings($null, [DisplayConfig]::ENUM_CURRENT_SETTINGS, [ref]$devMode) | Out-Null

        $devMode.dmPelsWidth        = $Config.ResolutionW
        $devMode.dmPelsHeight       = $Config.ResolutionH
        $devMode.dmDisplayFrequency = $Config.RefreshRate
        $devMode.dmFields = [DisplayConfig]::DM_PELSWIDTH -bor
                            [DisplayConfig]::DM_PELSHEIGHT -bor
                            [DisplayConfig]::DM_DISPLAYFREQUENCY

        $result = [DisplayConfig]::ChangeDisplaySettingsEx($null, [ref]$devMode, [IntPtr]::Zero, [DisplayConfig]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)

        if ($result -eq 0) {
            Write-Ok "Resolution set: $($Config.ResolutionW)x$($Config.ResolutionH) @ $($Config.RefreshRate)Hz"
        } else {
            Write-Info "ChangeDisplaySettingsEx code: $result (may need reboot)"
        }
    } else {
        Write-Info 'Virtual display not visible yet — reboot recommended'
    }
} catch {
    Write-Err "Resolution config error: $_"
}

# ─── 7. Final Summary ─────────────────────────────────────────────────────────

Write-Host "`n════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Provisioning & Driver Setup Complete" -ForegroundColor Green
Write-Host "════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Optimizations : RDP 60 FPS, TCP NoDelay, Dark Mode, ar-SA"
Write-Host "  Driver        : MttVDD (Virtual Display)"
Write-Host "  Resolution    : $($Config.ResolutionW)x$($Config.ResolutionH) @ $($Config.RefreshRate)Hz"
Write-Host "════════════════════════════════════════" -ForegroundColor Green
