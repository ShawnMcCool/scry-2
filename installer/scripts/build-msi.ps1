#!/usr/bin/env pwsh
#
# Build the Scry2 MSI installer and Burn bootstrapper.
# Run from the repo root after building the Elixir release and tray binary.
#
# Usage:
#   installer/scripts/build-msi.ps1 -Version 0.5.0 -TrayExe scry2-tray.exe -VCRedistPath installer/vc_redist.x64.exe
#
# Requires: wix CLI (dotnet tool install --global wix)
# Extensions: WixToolset.UI.wixext, WixToolset.Util.wixext, WixToolset.Firewall.wixext, WixToolset.BootstrapperApplications.wixext

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

# Resolve paths to absolute (WiX resolves relative paths from .wxs file location)
$ReleaseDir = (Resolve-Path $ReleaseDir).Path
$TrayExe = (Resolve-Path $TrayExe).Path
$VCRedistPath = (Resolve-Path $VCRedistPath).Path

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

# Generate WiX fragments from release directories
# WiX v5's <Files> element doesn't work reliably with the CLI tool,
# so we generate component fragments programmatically (like heat.exe did).
function New-WixFragment {
    param(
        [string]$SourceDir,
        [string]$ComponentGroupId,
        [string]$DirectoryId,
        [string]$OutputFile
    )

    $files = Get-ChildItem -Path $SourceDir -Recurse -File
    $fileCount = $files.Count
    Write-Host "  $ComponentGroupId`: $fileCount files"

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Fragment>
    <DirectoryRef Id="$DirectoryId">

"@

    # Track directories we've opened
    $openDirs = @{}
    $componentRefs = @()
    $fileIndex = 0

    foreach ($file in ($files | Sort-Object { $_.DirectoryName })) {
        $fileIndex++
        $relPath = $file.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
        $relDir = Split-Path $relPath -Parent

        # Build directory nesting
        if ($relDir -and -not $openDirs.ContainsKey($relDir)) {
            $parts = $relDir -split '[/\\]'
            $accumulated = ""
            foreach ($part in $parts) {
                $parent = $accumulated
                $accumulated = if ($accumulated) { "$accumulated\$part" } else { $part }
                if (-not $openDirs.ContainsKey($accumulated)) {
                    $dirId = "${ComponentGroupId}_d_" + ($accumulated -replace '[^a-zA-Z0-9]', '_')
                    $xml += "      <Directory Id=`"$dirId`" Name=`"$part`">`n"
                    $openDirs[$accumulated] = $dirId
                }
            }
        }

        $compId = "${ComponentGroupId}_$fileIndex"
        $fileId = "${ComponentGroupId}_f_$fileIndex"
        $sourcePath = $file.FullName -replace '/', '\'

        $xml += @"
      <Component Id="$compId" Guid="*">
        <File Id="$fileId" Source="$sourcePath" KeyPath="yes" />
      </Component>

"@
        $componentRefs += $compId
    }

    # Close all opened directories (in reverse order)
    $sortedDirs = $openDirs.Keys | Sort-Object { ($_ -split '[/\\]').Count } -Descending
    foreach ($dir in $sortedDirs) {
        $xml += "      </Directory>`n"
    }

    $xml += @"
    </DirectoryRef>
  </Fragment>
  <Fragment>
    <ComponentGroup Id="$ComponentGroupId">

"@
    foreach ($ref in $componentRefs) {
        $xml += "      <ComponentRef Id=`"$ref`" />`n"
    }

    $xml += @"
    </ComponentGroup>
  </Fragment>
</Wix>
"@

    $xml | Out-File -FilePath $OutputFile -Encoding UTF8
}

Write-Host "Generating WiX fragments from release directories..."

$fragments = @(
    @{ Dir = "$ReleaseDir\bin";           Group = "BinComponents";      DrId = "BinDir";      Out = "$WixDir\BinFragment.wxs" },
    @{ Dir = "$ReleaseDir\$ertsVersion";  Group = "ErtsComponents";     DrId = "ErtsDir";     Out = "$WixDir\ErtsFragment.wxs" },
    @{ Dir = "$ReleaseDir\lib";           Group = "LibComponents";      DrId = "LibDir";      Out = "$WixDir\LibFragment.wxs" },
    @{ Dir = "$ReleaseDir\releases";      Group = "ReleasesComponents"; DrId = "ReleasesDir"; Out = "$WixDir\ReleasesFragment.wxs" }
)

foreach ($frag in $fragments) {
    New-WixFragment -SourceDir $frag.Dir -ComponentGroupId $frag.Group -DirectoryId $frag.DrId -OutputFile $frag.Out
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
    -ext WixToolset.BootstrapperApplications.wixext `
    -ext WixToolset.Util.wixext `
    -o $bundlePath

if ($LASTEXITCODE -ne 0) {
    Write-Error "Burn bootstrapper build failed"
    exit 1
}
Write-Host "Bootstrapper built: $bundlePath"

# Clean up generated fragments
Remove-Item "$WixDir/*Fragment.wxs" -Force

Write-Host "Done. Artifacts in $OutputDir/"
