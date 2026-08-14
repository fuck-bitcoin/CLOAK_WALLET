# CLOAK Wallet manual trust-bootstrap installer for Windows x64.
# It replaces only application files. Wallet data, proving parameters,
# preferences, and local TLS material are deliberately preserved.

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repository = "fuck-bitcoin/CLOAK_WALLET"
$artifact = "CLOAK_Wallet-windows-x64.zip"
$version = if ($env:CLOAK_VERSION) { $env:CLOAK_VERSION } else { "latest" }
$installDirectory = if ($env:CLOAK_INSTALL_DIR) {
    [IO.Path]::GetFullPath($env:CLOAK_INSTALL_DIR)
} else {
    [IO.Path]::GetFullPath("$env:LOCALAPPDATA\cloak-wallet")
}
$appDirectory = Join-Path $installDirectory "app"
$previousDirectory = Join-Path $installDirectory "app.previous"
$token = [Guid]::NewGuid().ToString("N")
$stagingDirectory = Join-Path $installDirectory "app.staging-$token"
$zipPath = Join-Path ([IO.Path]::GetTempPath()) "$token-$artifact"
$healthFile = Join-Path ([IO.Path]::GetTempPath()) "cloak-wallet-update-$token.ok"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "PowerShell 5.1 or later is required"
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw "CLOAK Wallet requires 64-bit Windows"
}
if ($version -ne "latest" -and $version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "CLOAK_VERSION must be latest or vMAJOR.MINOR.PATCH"
}

$releaseBase = if ($version -eq "latest") {
    "https://github.com/$repository/releases/latest/download"
} else {
    "https://github.com/$repository/releases/download/$version"
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
$runningWallet = Get-Process -Name "cloak-wallet" -ErrorAction SilentlyContinue | Where-Object {
    try {
        $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith(
            $appDirectory,
            [StringComparison]::OrdinalIgnoreCase
        )
    } catch { $false }
}
if ($runningWallet) {
    throw "Close CLOAK Wallet before installing the baseline"
}

Write-Host "Downloading the CLOAK Wallet trust baseline..." -ForegroundColor White
$webClient = New-Object System.Net.WebClient
$webClient.DownloadFile("$releaseBase/$artifact", $zipPath)
$checksums = $webClient.DownloadString("$releaseBase/SHA256SUMS-windows")
$expectedHash = (($checksums -split "`n" | Where-Object {
    $_ -match "\s\*?$([regex]::Escape($artifact))\s*$"
} | Select-Object -First 1) -split "\s+")[0].Trim().ToLowerInvariant()
$actualHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedHash -notmatch '^[0-9a-f]{64}$' -or $expectedHash -ne $actualHash) {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    throw "Release checksum verification failed"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $stagingRoot = [IO.Path]::GetFullPath($stagingDirectory).TrimEnd('\') + '\'
    foreach ($entry in $archive.Entries) {
        if ([IO.Path]::IsPathRooted($entry.FullName)) {
            throw "Archive contains a rooted path"
        }
        $target = [IO.Path]::GetFullPath((Join-Path $stagingDirectory $entry.FullName))
        if (-not $target.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Archive path escapes the staging directory"
        }
    }
} finally {
    $archive.Dispose()
}

New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
Expand-Archive -Path $zipPath -DestinationPath $stagingDirectory -Force
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
$stagedExecutables = @(Get-ChildItem -Path $stagingDirectory `
    -Filter "cloak-wallet.exe" -Recurse -File)
if ($stagedExecutables.Count -ne 1) {
    Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    throw "The verified archive must contain exactly one CLOAK Wallet executable"
}
$stagedAppDirectory = [IO.Path]::GetFullPath(
    $stagedExecutables[0].Directory.FullName
).TrimEnd('\')
$stagingRootDirectory = [IO.Path]::GetFullPath($stagingDirectory).TrimEnd('\')
if ($stagedAppDirectory -ne $stagingRootDirectory) {
    $topLevelEntries = @(Get-ChildItem -LiteralPath $stagingRootDirectory -Force)
    if ($topLevelEntries.Count -ne 1 -or
        -not $topLevelEntries[0].PSIsContainer -or
        [IO.Path]::GetFullPath($topLevelEntries[0].FullName).TrimEnd('\') -ne
            $stagedAppDirectory) {
        Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw "The verified archive must contain one top-level application directory"
    }
}
if (-not (Test-Path (Join-Path $stagedAppDirectory 'cloak-wallet.exe') -PathType Leaf)) {
    throw "The staged application executable is not at its managed root"
}

if (Test-Path $previousDirectory) {
    Remove-Item $previousDirectory -Recurse -Force
}
if (Test-Path $appDirectory) {
    Move-Item -LiteralPath $appDirectory -Destination $previousDirectory
}
try {
    Move-Item -LiteralPath $stagedAppDirectory -Destination $appDirectory
    if (Test-Path $stagingDirectory) {
        Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    if ((-not (Test-Path $appDirectory)) -and (Test-Path $previousDirectory)) {
        Move-Item -LiteralPath $previousDirectory -Destination $appDirectory
    }
    throw
}

$executable = Get-Item (Join-Path $appDirectory 'cloak-wallet.exe') `
    -ErrorAction SilentlyContinue
if (-not $executable) { throw "Activated executable is missing" }

Write-Host "Windows SmartScreen may say Unknown publisher." -ForegroundColor Yellow
Write-Host "Choose More info, then Run anyway to complete the health check." -ForegroundColor Yellow
Remove-Item $healthFile -Force -ErrorAction SilentlyContinue
$healthProcess = $null
try {
    $healthProcess = Start-Process -FilePath $executable.FullName `
        -ArgumentList "--cloak-update-health=$token" -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and
           -not (Test-Path $healthFile) -and
           -not $healthProcess.HasExited) {
        Start-Sleep -Milliseconds 250
        $healthProcess.Refresh()
    }
    if (-not (Test-Path $healthFile)) {
        throw "The baseline did not acknowledge healthy startup"
    }
} catch {
    if ($healthProcess -and -not $healthProcess.HasExited) {
        Stop-Process -Id $healthProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $failedDirectory = Join-Path $installDirectory "app.failed-$token"
    if (Test-Path $appDirectory) {
        Move-Item -LiteralPath $appDirectory -Destination $failedDirectory `
            -ErrorAction SilentlyContinue
    }
    if (Test-Path $previousDirectory) {
        Move-Item -LiteralPath $previousDirectory -Destination $appDirectory
        $restored = Get-ChildItem -Path $appDirectory -Filter "cloak-wallet.exe" `
            -Recurse -File | Select-Object -First 1
        if ($restored) { Start-Process -FilePath $restored.FullName }
    }
    throw "Baseline health check failed; the previous app was restored. $_"
}

$shell = New-Object -ComObject WScript.Shell
$startMenuLink = Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" `
    "CLOAK Wallet.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "CLOAK Wallet.lnk"
foreach ($link in @($startMenuLink, $desktopLink)) {
    try {
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = $executable.FullName
        $shortcut.WorkingDirectory = $executable.DirectoryName
        $shortcut.Description = "CLOAK Privacy Wallet"
        $shortcut.Save()
    } catch {
        Write-Host "Could not create shortcut: $link" -ForegroundColor Yellow
    }
}

Write-Host "CLOAK Wallet installed at $($executable.FullName)" -ForegroundColor Green
Write-Host "Wallet data, parameters, preferences, and local TLS files were preserved."
