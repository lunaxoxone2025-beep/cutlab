# Downloads a prebuilt LGPL, shared FFmpeg for Windows x64 (BtbN/FFmpeg-Builds)
# and makes sure MSVC import libraries (.lib) exist.
#
#   pwsh scripts/ffmpeg/fetch_ffmpeg_windows.ps1 -Dest build/ffmpeg-win64 [-Series n7.1]
#
# Needs the GitHub CLI (gh) with a token (GH_TOKEN) to list release assets.
param(
  [Parameter(Mandatory = $true)][string]$Dest,
  [string]$Series = "n7.1"
)
$ErrorActionPreference = "Stop"

$assets = gh release view latest -R BtbN/FFmpeg-Builds --json assets --jq '.assets[].name'
$want = "ffmpeg-$Series-latest-win64-lgpl-shared-*.zip"
$name = $assets | Where-Object { $_ -like $want } | Select-Object -First 1
if (-not $name) {
  Write-Host "Available Windows LGPL shared builds:"
  $assets | Where-Object { $_ -like "*win64-lgpl-shared*" } | ForEach-Object { Write-Host "  $_" }
  throw "No $want in BtbN/FFmpeg-Builds 'latest'."
}
Write-Host "Using $name"

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$zip = Join-Path $env:RUNNER_TEMP $name
gh release download latest -R BtbN/FFmpeg-Builds -p $name -O $zip --clobber
$tmp = Join-Path $env:RUNNER_TEMP "ffmpeg-extract"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Expand-Archive -Path $zip -DestinationPath $tmp
$root = Get-ChildItem $tmp -Directory | Select-Object -First 1
Copy-Item -Recurse -Force (Join-Path $root.FullName "*") $Dest

# MSVC needs <name>.lib import libraries. Generate them from the DLL exports
# when the archive only ships MinGW .dll.a files.
$lib = Join-Path $Dest "lib"
foreach ($n in @("avformat", "avcodec", "avutil", "swscale", "swresample")) {
  if (Test-Path (Join-Path $lib "$n.lib")) { continue }
  $dll = Get-ChildItem (Join-Path $Dest "bin") -Filter "$n-*.dll" | Select-Object -First 1
  if (-not $dll) { throw "missing $n DLL" }
  $def = Join-Path $lib "$n.def"
  $exports = & dumpbin /exports $dll.FullName | Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
  @("LIBRARY $($dll.Name)", "EXPORTS") + $exports | Set-Content -Encoding ascii $def
  & lib /nologo /machine:x64 "/def:$def" "/out:$(Join-Path $lib "$n.lib")"
  Write-Host "Generated $n.lib from $($dll.Name)"
}
Get-ChildItem $lib, (Join-Path $Dest "bin") | ForEach-Object { Write-Host $_.FullName }
