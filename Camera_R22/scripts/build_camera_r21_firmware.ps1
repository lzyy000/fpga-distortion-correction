param([string]$Implementation='pnr_camera_r21_modes')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'build_camera_r22_firmware.ps1') -Implementation $Implementation
