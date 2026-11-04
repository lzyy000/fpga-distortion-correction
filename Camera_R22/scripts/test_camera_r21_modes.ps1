param([switch]$CheckOnly,[switch]$FullFrame)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test_camera_r22.ps1') @PSBoundParameters
