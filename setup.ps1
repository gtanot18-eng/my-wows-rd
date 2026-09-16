#Requires -RunAsAdministrator

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$Config = @{
    DriverRepo   = "https://github.com/itsmikethetech/Virtual-Display-Driver"
    ReleasesApi  = "https://api.github.com/repos/itsmikethetech/Virtual-Display-Driver/releases/latest"
    InstallDir   = "C:\VirtualDisplay"
    ResolutionW  = 1920
    ResolutionH  = 1080
    RefreshRate  = 60
}

function Write-Section ([string]$Title) { Write-Host "`n=== $Title ===" -ForegroundColor Cyan }
function Write-Ok   ([string]$Msg) { Write-Host "  [+] $Msg" -ForegroundColor Green }
function Write-Info ([string]$Msg) { Write-Host "  [*] $Msg" -ForegroundColor Yellow }
function Write-Err  ([string]$Msg) { Write-Host "  [!] $Msg" -ForegroundColor Red }

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Ok "$Name = $Value"
    } catch {
        Write-Err "Registry error: $_"
    }
}

# 1. RDP Performance
Write-Section "RDP Performance Setup"
Set-RegValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Name "DWMFRAMEINTERVAL" -Value 15

# 2. TCP Low-Latency
Write-Section "TCP Low-Latency Configuration"
$TcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
Set-RegValue -Path $TcpParams -Name "TcpAckFrequency" -Value 1
Set-RegValue -Path $TcpParams -Name "TCPNoDelay" -Value 1

# 3. UI Theme
Write-Section "System Dark Theme"
$ThemePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
Set-RegValue -Path $ThemePath -Name "AppsUseLightTheme" -Value 0
Set-RegValue -Path $ThemePath -Name "SystemUsesLightTheme" -Value 0

# 4. Driver Setup
Write-Section "Preparing Virtual Display Directory"
if (-not (Test-Path $Config.InstallDir)) { New-Item -Path $Config.InstallDir -ItemType Directory -Force | Out-Null }

Write-Section "Downloading Virtual Display Driver"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri $Config.ReleasesApi -UseBasicParsing
    $asset   = $release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
    $zipPath = Join-Path $Config.InstallDir "$($asset.name)"
    
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    Write-Ok "Downloaded: $zipPath"

    $extractPath = Join-Path $Config.InstallDir "driver"
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    
    $infFile = Get-ChildItem -Path $extractPath -Filter "*.inf" -Recurse | Select-Object -First 1
    if ($infFile) {
        Write-Section "Installing Driver"
        & pnputil /add-driver "$($infFile.FullName)" /install
        Write-Ok "Driver installation command executed"
    }
} catch {
    Write-Err "Driver setup warning: $_"
}

Write-Host "`n[+] Provisioning Script Finished." -ForegroundColor Green
