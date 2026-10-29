# Builds a Content Manager-friendly zip: HeadSync-v<version>.zip
# containing apps/lua/HeadSync/... so it can be dragged straight onto CM.
# Usage: right-click > Run with PowerShell, or `./build.ps1` from a terminal.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$manifest = Join-Path $root 'HeadSync/manifest.ini'
$version = (Select-String -Path $manifest -Pattern '^VERSION\s*=\s*(.+)$').Matches[0].Groups[1].Value.Trim()

$dist = Join-Path $root 'dist'
$staging = Join-Path $dist 'apps/lua'
Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $staging | Out-Null

# Copy the app, minus any debug leftovers
Copy-Item -Recurse (Join-Path $root 'HeadSync') $staging
Remove-Item (Join-Path $staging 'HeadSync/nodes.txt') -ErrorAction SilentlyContinue

$zip = Join-Path $root "HeadSync-v$version.zip"
Compress-Archive -Path (Join-Path $dist 'apps') -DestinationPath $zip -Force
Remove-Item -Recurse -Force $dist

Write-Host "Built $zip"
