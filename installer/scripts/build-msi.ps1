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

    # Two-pass approach: build directory tree first, then emit components.
    # Everything in one Fragment so the WiX v5 linker includes it.

    # Pass 1: Collect all unique directory paths and build a tree
    $allDirs = @{}  # path -> dirId
    $allDirs[""] = $DirectoryId  # root maps to the parent DirectoryRef
    $fileEntries = @()

    $fileIndex = 0
    foreach ($file in $files) {
        $fileIndex++
        $relPath = $file.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
        $relDir = (Split-Path $relPath -Parent) -replace '/', '\'

        # Register all directory segments
        if ($relDir) {
            $parts = $relDir -split '\\'
            $accumulated = ""
            foreach ($part in $parts) {
                $accumulated = if ($accumulated) { "$accumulated\$part" } else { $part }
                if (-not $allDirs.ContainsKey($accumulated)) {
                    $dirId = "${ComponentGroupId}_d_" + ($accumulated -replace '[^a-zA-Z0-9]', '_')
                    $allDirs[$accumulated] = $dirId
                }
            }
        }

        $compId = "${ComponentGroupId}_$fileIndex"
        $fileId = "${ComponentGroupId}_f_$fileIndex"
        $dirId = if ($relDir) { $allDirs[$relDir] } else { $DirectoryId }
        $sourcePath = $file.FullName -replace '/', '\'

        $fileEntries += @{ CompId = $compId; FileId = $fileId; DirId = $dirId; Source = $sourcePath }
    }

    # Emit directory tree recursively
    function Write-DirTree {
        param([string]$ParentPath, [string]$Indent)
        # Find direct children of this parent
        $children = $allDirs.Keys | Where-Object {
            $_ -ne "" -and $_ -ne $ParentPath -and
            $(if ($ParentPath) { $_.StartsWith("$ParentPath\") -and ($_ -replace "^$([regex]::Escape($ParentPath))\\", "") -notmatch '\\' } else { $_ -notmatch '\\' })
        } | Sort-Object

        $result = ""
        foreach ($child in $children) {
            $name = if ($ParentPath) { $child.Substring($ParentPath.Length + 1) } else { $child }
            $id = $allDirs[$child]
            $result += "$Indent<Directory Id=`"$id`" Name=`"$name`">`n"
            $result += (Write-DirTree -ParentPath $child -Indent "$Indent  ")
            $result += "$Indent</Directory>`n"
        }
        return $result
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Fragment>
    <DirectoryRef Id="$DirectoryId">
$(Write-DirTree -ParentPath "" -Indent "      ")    </DirectoryRef>

"@

    # Pass 2: Emit components grouped by directory, using DirectoryRef
    $byDir = $fileEntries | Group-Object { $_.DirId }
    foreach ($group in $byDir) {
        $xml += "    <DirectoryRef Id=`"$($group.Name)`">`n"
        foreach ($entry in $group.Group) {
            $xml += "      <Component Id=`"$($entry.CompId)`" Guid=`"*`">`n"
            $xml += "        <File Id=`"$($entry.FileId)`" Source=`"$($entry.Source)`" KeyPath=`"yes`" />`n"
            $xml += "      </Component>`n"
        }
        $xml += "    </DirectoryRef>`n"
    }

    # ComponentGroup in the same fragment
    $xml += "`n    <ComponentGroup Id=`"$ComponentGroupId`">`n"
    foreach ($entry in $fileEntries) {
        $xml += "      <ComponentRef Id=`"$($entry.CompId)`" />`n"
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
