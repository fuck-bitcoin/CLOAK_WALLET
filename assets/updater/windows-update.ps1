param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$CurrentDir,
  [Parameter(Mandatory = $true)][string]$StagedDir,
  [Parameter(Mandatory = $true)][string]$PreviousDir,
  [Parameter(Mandatory = $true)][string]$HealthToken
)

$ErrorActionPreference = "Stop"
if ($HealthToken -notmatch '^[0-9a-f]{32}$') { throw "Invalid health token" }

$current = [IO.Path]::GetFullPath($CurrentDir).TrimEnd('\')
$staged = [IO.Path]::GetFullPath($StagedDir).TrimEnd('\')
$previous = [IO.Path]::GetFullPath($PreviousDir).TrimEnd('\')
$managed = [IO.Path]::GetFullPath(
  (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'cloak-wallet\app')
).TrimEnd('\')
$parent = [IO.Directory]::GetParent($managed).FullName.TrimEnd('\')
$expectedStaged = [IO.Path]::GetFullPath(
  (Join-Path $parent ".cloak-update-$HealthToken")
).TrimEnd('\')
$expectedPrevious = "$managed.previous"
if ($current -ine $managed -or $staged -ine $expectedStaged -or
    $previous -ine $expectedPrevious) {
  throw "Updater paths do not match the managed CLOAK installation"
}
if (-not (Test-Path (Join-Path $staged 'cloak-wallet.exe'))) {
  throw "Staged executable is missing"
}
$readyFile = Join-Path ([IO.Path]::GetTempPath()) "cloak-wallet-update-$HealthToken.ready"
Set-Content -LiteralPath $readyFile -Value $HealthToken -NoNewline

Wait-Process -Id $ParentPid -Timeout 90 -ErrorAction SilentlyContinue
if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
  exit 3
}
$healthFile = Join-Path ([IO.Path]::GetTempPath()) "cloak-wallet-update-$HealthToken.ok"
Remove-Item $healthFile -Force -ErrorAction SilentlyContinue

if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
Move-Item -LiteralPath $current -Destination $previous
$process = $null
try {
  Move-Item -LiteralPath $staged -Destination $current
  $process = Start-Process -FilePath (Join-Path $current 'cloak-wallet.exe') `
    -ArgumentList "--cloak-update-health=$HealthToken" -PassThru
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and -not (Test-Path $healthFile) -and -not $process.HasExited) {
    Start-Sleep -Milliseconds 250
    $process.Refresh()
  }
  if (-not (Test-Path $healthFile)) { throw "Updated wallet failed its health check" }
} catch {
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
  $failed = "$current.failed-$HealthToken"
  if (Test-Path $failed) { Remove-Item $failed -Recurse -Force }
  if (Test-Path $current) { Move-Item -LiteralPath $current -Destination $failed }
  Move-Item -LiteralPath $previous -Destination $current
  Start-Process -FilePath (Join-Path $current 'cloak-wallet.exe')
  exit 1
}
