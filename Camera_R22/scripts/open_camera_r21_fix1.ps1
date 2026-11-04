param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
# Compatibility entry: always opens the current R21 source revision.
& (Join-Path $PSScriptRoot 'open_camera_r21.ps1') -CheckOnly:$CheckOnly
