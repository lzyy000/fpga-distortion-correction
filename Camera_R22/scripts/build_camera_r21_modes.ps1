param([switch]$CheckOnly,[switch]$SkipValidation)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'build_camera_r22.ps1') @PSBoundParameters
