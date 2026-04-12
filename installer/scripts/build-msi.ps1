#!/usr/bin/env pwsh
#
# Build the Scry2 MSI installer and Burn bootstrapper.
# Run from the repo root after building the Elixir release and tray binary.
#
# Usage:
#   installer/scripts/build-msi -Version 0.5.0 -TrayExe scry2-tray.exe -VCRedistPath installer/vc_redist.x64.exe
#
# Requires: wix CLI (dotnet tool install --global wix)
# Extensions: WixToolset.UI.wixext, WixToolset.Util.wixext, WixToolset.Firewall.wixext, WixToolset.Bal.wixext

param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [string]$TrayExe,

    [Parameter(Mandatory=$true)]
    [string]$VCRedistPath,

    [string]$ReleaseDir = "_build/prod/rel/scry_2",
    [string]$OutputDir = "installer/output"
)

$ErrorActionPreference = "Stop"
$WixDir = "$PSScriptRoot/../wix"

# Detect ERTS version from the release directory
$ertsDir = Get-ChildItem "$ReleaseDir/erts-*" -Directory | Select-Object -First 1
if (-not $ertsDir) {
    Write-Error "No erts-* directory found in $ReleaseDir"
    exit 1
}
$ertsVersion = $ertsDir.Name
Write-Host "Detected ERTS version: $ertsVersion"

# Create output directory
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Harvest release directories into WiX fragments
Write-Host "Harvesting release files..."

$harvestJobs = @(
    @{ Dir = "$ReleaseDir/bin";       Group = "BinComponents";      DrId = "BinDir";      Out = "$WixDir/BinFragment.wxs" },
    @{ Dir = "$ReleaseDir/$ertsVersion"; Group = "ErtsComponents";   DrId = "ErtsDir";     Out = "$WixDir/ErtsFragment.wxs" },
    @{ Dir = "$ReleaseDir/lib";       Group = "LibComponents";      DrId = "LibDir";      Out = "$WixDir/LibFragment.wxs" },
    @{ Dir = "$ReleaseDir/releases";  Group = "ReleasesComponents"; DrId = "ReleasesDir"; Out = "$WixDir/ReleasesFragment.wxs" }
)

foreach ($job in $harvestJobs) {
    Write-Host "  Harvesting $($job.Dir)..."
    wix harvest dir $job.Dir -cg $job.Group -dr $job.DrId -o $job.Out
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to harvest $($job.Dir)"
        exit 1
    }
}

# Build the MSI
Write-Host "Building MSI..."
$msiPath = "$OutputDir/Scry2-$Version.msi"

$wxsFiles = @(
    "$WixDir/Package.wxs",
    "$WixDir/Directories.wxs",
    "$WixDir/Components.wxs",
    "$WixDir/Features.wxs",
    "$WixDir/Firewall.wxs",
    "$WixDir/Registry.wxs",
    "$WixDir/UI.wxs",
    "$WixDir/LegacyCleanup.wxs",
    "$WixDir/BinFragment.wxs",
    "$WixDir/ErtsFragment.wxs",
    "$WixDir/LibFragment.wxs",
    "$WixDir/ReleasesFragment.wxs"
)

$wixArgs = @("build") + $wxsFiles + @(
    "-d", "Version=$Version",
    "-d", "ErtsVersion=$ertsVersion",
    "-d", "InstallSource=$ReleaseDir",
    "-d", "TrayExe=$TrayExe",
    "-ext", "WixToolset.UI.wixext",
    "-ext", "WixToolset.Util.wixext",
    "-ext", "WixToolset.Firewall.wixext",
    "-o", $msiPath
)

wix @wixArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "MSI build failed"
    exit 1
}
Write-Host "MSI built: $msiPath"

# Build the Burn bootstrapper
Write-Host "Building Burn bootstrapper..."
$bundlePath = "$OutputDir/Scry2Setup-v$Version.exe"

wix build "$WixDir/Bundle.wxs" `
    -d "Version=$Version" `
    -d "MsiPath=$msiPath" `
    -d "VCRedistPath=$VCRedistPath" `
    -ext WixToolset.Bal.wixext `
    -ext WixToolset.Util.wixext `
    -o $bundlePath

if ($LASTEXITCODE -ne 0) {
    Write-Error "Burn bootstrapper build failed"
    exit 1
}
Write-Host "Bootstrapper built: $bundlePath"

# Clean up harvested fragments
Remove-Item "$WixDir/*Fragment.wxs" -Force

Write-Host "Done. Artifacts in $OutputDir/"
