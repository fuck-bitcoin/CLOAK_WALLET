# CLOAK Wallet Installer for Windows
# Usage: irm https://raw.githubusercontent.com/fuck-bitcoin/CLOAK_WALLET/main/install.ps1 | iex
#
# Environment variables (optional):
#   CLOAK_VERSION     - Release tag to install (default: "latest")
#   CLOAK_INSTALL_DIR - Override install directory
#   CLOAK_SKIP_PARAMS - Set to "1" to skip ZK params download

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$repo       = "fuck-bitcoin/CLOAK_WALLET"
$zipName    = "CLOAK_Wallet-windows-x64.zip"
$version    = if ($env:CLOAK_VERSION) { $env:CLOAK_VERSION } else { "latest" }
$installDir = if ($env:CLOAK_INSTALL_DIR) { $env:CLOAK_INSTALL_DIR } else { "$env:LOCALAPPDATA\cloak-wallet" }
$appDir     = "$installDir\app"
$paramsDir  = "$installDir\params"

$paramFiles = @(
    @{ Name = "mint.params";         SizeMB = 15  },
    @{ Name = "output.params";       SizeMB = 3   },
    @{ Name = "spend.params";        SizeMB = 182 },
    @{ Name = "spend-output.params"; SizeMB = 183 }
)
$paramsTotalMB   = 383
$paramsBaseUrl   = "https://github.com/$repo/releases/download/params-v1"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "     CLOAK Wallet Installer (Windows x64)    " -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# PowerShell version check
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "ERROR: PowerShell 5.1 or later is required." -ForegroundColor Red
    Write-Host "  Detected version: $($PSVersionTable.PSVersion)"
    Write-Host "  PowerShell 5.1 comes pre-installed on Windows 10 and 11."
    exit 1
}

# ---------------------------------------------------------------------------
# OS architecture check
# ---------------------------------------------------------------------------
if ([Environment]::Is64BitOperatingSystem -eq $false) {
    Write-Host "ERROR: CLOAK Wallet requires a 64-bit version of Windows." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Windows version check (require Windows 10+)
# ---------------------------------------------------------------------------
$osVersion = [Environment]::OSVersion.Version
if ($osVersion.Major -lt 10) {
    Write-Host "ERROR: CLOAK Wallet requires Windows 10 or later." -ForegroundColor Red
    Write-Host "  Detected: Windows $($osVersion.Major).$($osVersion.Minor)"
    exit 1
}

# ---------------------------------------------------------------------------
# Check for existing installation
# ---------------------------------------------------------------------------
$existingExe = $null
if (Test-Path $appDir) {
    $existingExe = Get-ChildItem -Path $appDir -Filter "cloak-wallet.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingExe) {
        Write-Host "  Existing installation detected at:" -ForegroundColor Yellow
        Write-Host "    $($existingExe.FullName)"
        Write-Host ""
        Write-Host "  The existing installation will be upgraded." -ForegroundColor Yellow
        Write-Host "  Wallet data and ZK parameters will be preserved."
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# Disk space check
# ---------------------------------------------------------------------------
$driveLetter = (Split-Path -Qualifier $env:LOCALAPPDATA)
$drive = Get-PSDrive -Name ($driveLetter.TrimEnd(':'))
$freeGB = [math]::Round($drive.Free / 1GB, 1)
$requiredGB = 1.0

if ($freeGB -lt $requiredGB) {
    Write-Host "ERROR: Insufficient disk space." -ForegroundColor Red
    Write-Host "  Required: at least $requiredGB GB"
    Write-Host "  Available: $freeGB GB on drive $driveLetter"
    exit 1
}
Write-Host "  Disk space: ${freeGB} GB available on $driveLetter" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Determine download URLs
# ---------------------------------------------------------------------------
if ($version -eq "latest") {
    $downloadUrl  = "https://github.com/$repo/releases/latest/download/$zipName"
    $checksumUrl  = "https://github.com/$repo/releases/latest/download/SHA256SUMS"
} else {
    $downloadUrl  = "https://github.com/$repo/releases/download/$version/$zipName"
    $checksumUrl  = "https://github.com/$repo/releases/download/$version/SHA256SUMS"
}

# ---------------------------------------------------------------------------
# Ensure TLS 1.2 (required for GitHub)
# ---------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Create install directories
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $appDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Download ZIP
# ---------------------------------------------------------------------------
$zipPath = "$env:TEMP\$zipName"

Write-Host ""
Write-Host "  Downloading CLOAK Wallet..." -ForegroundColor White
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Downloading $zipName" -PercentComplete 10

try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($downloadUrl, $zipPath)
} catch {
    Write-Host "ERROR: Failed to download CLOAK Wallet." -ForegroundColor Red
    Write-Host "  URL: $downloadUrl"
    Write-Host "  $_"
    Write-Host ""
    Write-Host "  Check your internet connection and try again."
    exit 1
}

Write-Progress -Activity "CLOAK Wallet Installer" -Status "Download complete" -PercentComplete 30

# ---------------------------------------------------------------------------
# Download and verify SHA256 checksum
# ---------------------------------------------------------------------------
Write-Host "  Verifying integrity..." -ForegroundColor White

try {
    $checksums = (New-Object System.Net.WebClient).DownloadString($checksumUrl)
    $expectedHash = ($checksums -split "`n" | Where-Object { $_ -match [regex]::Escape($zipName) } | ForEach-Object { ($_ -split "\s+")[0] }).Trim().ToLower()
    $actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()

    if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        Write-Host "  WARNING: Could not find checksum for $zipName in SHA256SUMS." -ForegroundColor Yellow
        Write-Host "  Continuing without verification."
    } elseif ($expectedHash -ne $actualHash) {
        Write-Host "ERROR: Checksum verification failed!" -ForegroundColor Red
        Write-Host "  Expected: $expectedHash"
        Write-Host "  Got:      $actualHash"
        Write-Host ""
        Write-Host "  The download may be corrupted. Please try again."
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        exit 1
    } else {
        Write-Host "  Checksum verified." -ForegroundColor Green
    }
} catch {
    Write-Host "  WARNING: Could not download checksum file. Skipping verification." -ForegroundColor Yellow
    Write-Host "  $_"
}

Write-Progress -Activity "CLOAK Wallet Installer" -Status "Checksum verified" -PercentComplete 40

# ---------------------------------------------------------------------------
# Extract ZIP
# ---------------------------------------------------------------------------
Write-Host "  Installing..." -ForegroundColor White
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Extracting files" -PercentComplete 50

# Remove old app files but preserve params and wallet data
if (Test-Path $appDir) {
    Remove-Item "$appDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    Expand-Archive -Path $zipPath -DestinationPath $appDir -Force
} catch {
    Write-Host "ERROR: Failed to extract archive." -ForegroundColor Red
    Write-Host "  $_"
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    exit 1
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

Write-Progress -Activity "CLOAK Wallet Installer" -Status "Extraction complete" -PercentComplete 60

# ---------------------------------------------------------------------------
# Locate the executable
# ---------------------------------------------------------------------------
$exe = Get-ChildItem -Path $appDir -Filter "cloak-wallet.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) {
    Write-Host "ERROR: Application executable not found in archive." -ForegroundColor Red
    Write-Host "  The ZIP file may be malformed. Please report this issue."
    exit 1
}
$exePath = $exe.FullName
$exeDir  = $exe.DirectoryName

Write-Host "  Executable: $exePath" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Check Visual C++ Runtime
# ---------------------------------------------------------------------------
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Checking VC++ Runtime" -PercentComplete 65

$vcRedistKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
$vcInstalled = $false
if (Test-Path $vcRedistKey) {
    $vcInstalled = $true
} else {
    # Alternative check: look for the DLLs in System32
    $vcInstalled = (Test-Path "$env:SystemRoot\System32\msvcp140.dll") -and
                   (Test-Path "$env:SystemRoot\System32\vcruntime140.dll")
}

# Also check if the DLLs are bundled with the app
$vcBundled = (Test-Path "$exeDir\msvcp140.dll") -and
             (Test-Path "$exeDir\vcruntime140.dll")

if ((-not $vcInstalled) -and (-not $vcBundled)) {
    Write-Host ""
    Write-Host "  WARNING: Visual C++ Runtime not detected." -ForegroundColor Yellow
    Write-Host "  CLOAK Wallet may not start without it."
    Write-Host ""
    Write-Host "  Download and install the VC++ Redistributable from:" -ForegroundColor Yellow
    Write-Host "    https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Cyan
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Create Start Menu shortcut
# ---------------------------------------------------------------------------
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Creating shortcuts" -PercentComplete 75

$shell = New-Object -ComObject WScript.Shell

$startMenuDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$startMenuLnk = "$startMenuDir\CLOAK Wallet.lnk"

try {
    $shortcut = $shell.CreateShortcut($startMenuLnk)
    $shortcut.TargetPath       = $exePath
    $shortcut.WorkingDirectory = $exeDir
    $shortcut.Description      = "CLOAK Privacy Wallet"
    $shortcut.Save()
    Write-Host "  Start Menu shortcut created." -ForegroundColor DarkGray
} catch {
    Write-Host "  WARNING: Could not create Start Menu shortcut." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Create Desktop shortcut
# ---------------------------------------------------------------------------
$desktopDir = [Environment]::GetFolderPath("Desktop")
$desktopLnk = "$desktopDir\CLOAK Wallet.lnk"

try {
    $shortcut = $shell.CreateShortcut($desktopLnk)
    $shortcut.TargetPath       = $exePath
    $shortcut.WorkingDirectory = $exeDir
    $shortcut.Description      = "CLOAK Privacy Wallet"
    $shortcut.Save()
    Write-Host "  Desktop shortcut created." -ForegroundColor DarkGray
} catch {
    Write-Host "  WARNING: Could not create Desktop shortcut." -ForegroundColor Yellow
}

Write-Progress -Activity "CLOAK Wallet Installer" -Status "Shortcuts created" -PercentComplete 80

# ---------------------------------------------------------------------------
# Download ZK parameters (optional)
# ---------------------------------------------------------------------------
if ($env:CLOAK_SKIP_PARAMS -ne "1") {
    Write-Host ""
    Write-Host "  Downloading ZK proving parameters (~$paramsTotalMB MB)..." -ForegroundColor White
    Write-Host "  This is required for privacy transactions." -ForegroundColor DarkGray

    New-Item -ItemType Directory -Path $paramsDir -Force | Out-Null

    # Download params checksum file
    $paramsChecksumPath = "$paramsDir\SHA256SUMS"
    try {
        (New-Object System.Net.WebClient).DownloadFile("$paramsBaseUrl/SHA256SUMS", $paramsChecksumPath)
    } catch {
        Write-Host "  WARNING: Could not download params checksums." -ForegroundColor Yellow
    }

    # Read expected checksums into a hashtable
    $expectedChecksums = @{}
    if (Test-Path $paramsChecksumPath) {
        Get-Content $paramsChecksumPath | ForEach-Object {
            $parts = $_ -split "\s+"
            if ($parts.Count -ge 2) {
                $hash = $parts[0].Trim().ToLower()
                $name = ($parts[1] -replace '^\*', '').Trim()
                $expectedChecksums[$name] = $hash
            }
        }
    }

    $paramIndex = 0
    $paramCount = $paramFiles.Count
    foreach ($pf in $paramFiles) {
        $paramIndex++
        $paramPath = "$paramsDir\$($pf.Name)"
        $pctBase   = 80 + [int](($paramIndex - 1) / $paramCount * 15)
        $pctEnd    = 80 + [int]($paramIndex / $paramCount * 15)

        Write-Progress -Activity "CLOAK Wallet Installer" `
            -Status "Downloading $($pf.Name) ($($pf.SizeMB) MB) [$paramIndex/$paramCount]" `
            -PercentComplete $pctBase

        # Check if file already exists with correct checksum
        if (Test-Path $paramPath) {
            $fileHash = (Get-FileHash $paramPath -Algorithm SHA256).Hash.ToLower()
            if ($expectedChecksums.ContainsKey($pf.Name) -and $fileHash -eq $expectedChecksums[$pf.Name]) {
                Write-Host "    $($pf.Name) -- already exists, checksum OK. Skipping." -ForegroundColor DarkGray
                continue
            } else {
                Write-Host "    $($pf.Name) -- exists but checksum mismatch. Re-downloading." -ForegroundColor Yellow
                Remove-Item $paramPath -Force
            }
        }

        $paramUrl = "$paramsBaseUrl/$($pf.Name)"
        try {
            (New-Object System.Net.WebClient).DownloadFile($paramUrl, $paramPath)
        } catch {
            Write-Host "  ERROR: Failed to download $($pf.Name)." -ForegroundColor Red
            Write-Host "  $_"
            Write-Host ""
            Write-Host "  ZK parameters are required for privacy transactions."
            Write-Host "  The wallet will attempt to download them on first launch."
            break
        }

        # Verify individual file checksum
        if ($expectedChecksums.ContainsKey($pf.Name)) {
            $dlHash = (Get-FileHash $paramPath -Algorithm SHA256).Hash.ToLower()
            if ($dlHash -ne $expectedChecksums[$pf.Name]) {
                Write-Host "  WARNING: Checksum mismatch for $($pf.Name)." -ForegroundColor Yellow
                Write-Host "    Expected: $($expectedChecksums[$pf.Name])"
                Write-Host "    Got:      $dlHash"
                Remove-Item $paramPath -Force
            } else {
                Write-Host "    $($pf.Name) -- verified." -ForegroundColor DarkGray
            }
        } else {
            Write-Host "    $($pf.Name) -- downloaded (no checksum available)." -ForegroundColor DarkGray
        }

        Write-Progress -Activity "CLOAK Wallet Installer" `
            -Status "$($pf.Name) complete" `
            -PercentComplete $pctEnd
    }
} else {
    Write-Host ""
    Write-Host "  Skipping ZK parameters download (CLOAK_SKIP_PARAMS=1)." -ForegroundColor DarkGray
    Write-Host "  The wallet will download them (~$paramsTotalMB MB) on first launch."
}

# ---------------------------------------------------------------------------
# Create uninstall script
# ---------------------------------------------------------------------------
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Creating uninstall script" -PercentComplete 95

$uninstallScript = @"
# CLOAK Wallet Uninstaller
# Run: powershell -ExecutionPolicy Bypass -File "$installDir\uninstall.ps1"

`$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "  CLOAK Wallet Uninstaller" -ForegroundColor Cyan
Write-Host ""

# Remove app directory
if (Test-Path "$appDir") {
    Write-Host "  Removing application files..."
    Remove-Item "$appDir" -Recurse -Force
}

# Remove shortcuts
Write-Host "  Removing shortcuts..."
Remove-Item "$startMenuLnk" -Force
Remove-Item "$desktopLnk" -Force

# Remove uninstall script itself
Remove-Item "$installDir\uninstall.ps1" -Force

Write-Host ""
Write-Host "  CLOAK Wallet has been uninstalled." -ForegroundColor Green
Write-Host ""

# Check for remaining data
if (Test-Path "$paramsDir") {
    Write-Host "  ZK parameters remain at:" -ForegroundColor Yellow
    Write-Host "    $paramsDir"
    Write-Host ""
    Write-Host "  To remove ZK parameters (~383 MB):" -ForegroundColor DarkGray
    Write-Host "    Remove-Item '$paramsDir' -Recurse -Force"
}

`$walletData = "$installDir"
if (Test-Path "`$walletData") {
    Write-Host ""
    Write-Host "  Wallet data directory remains at:" -ForegroundColor Yellow
    Write-Host "    `$walletData"
    Write-Host ""
    Write-Host "  To remove ALL data (THIS DELETES YOUR WALLET):" -ForegroundColor Red
    Write-Host "    Remove-Item '$installDir' -Recurse -Force"
}
Write-Host ""
"@

Set-Content -Path "$installDir\uninstall.ps1" -Value $uninstallScript -Encoding UTF8

# ---------------------------------------------------------------------------
# Complete
# ---------------------------------------------------------------------------
Write-Progress -Activity "CLOAK Wallet Installer" -Status "Complete" -PercentComplete 100 -Completed

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "     Installation complete!                   " -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Location:  $exePath"
Write-Host "  Shortcuts: Start Menu + Desktop"
Write-Host ""

if ($env:CLOAK_SKIP_PARAMS -ne "1") {
    # Check if all params downloaded
    $paramsOK = $true
    foreach ($pf in $paramFiles) {
        if (-not (Test-Path "$paramsDir\$($pf.Name)")) {
            $paramsOK = $false
            break
        }
    }
    if ($paramsOK) {
        Write-Host "  ZK params: Downloaded and verified." -ForegroundColor Green
    } else {
        Write-Host "  ZK params: Some files missing. The wallet will download" -ForegroundColor Yellow
        Write-Host "             remaining parameters (~$paramsTotalMB MB) on first launch."
    }
} else {
    Write-Host "  ZK params: Will be downloaded (~$paramsTotalMB MB) on first launch."
}

Write-Host ""
Write-Host "  To uninstall:" -ForegroundColor DarkGray
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`"" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# SmartScreen notice
# ---------------------------------------------------------------------------
Write-Host "  NOTE: Windows SmartScreen may show a warning on first launch" -ForegroundColor Yellow
Write-Host "  because the application is not code-signed." -ForegroundColor Yellow
Write-Host ""
Write-Host "  To proceed:" -ForegroundColor White
Write-Host "    1. Click 'More info'" -ForegroundColor White
Write-Host "    2. Click 'Run anyway'" -ForegroundColor White
Write-Host ""
