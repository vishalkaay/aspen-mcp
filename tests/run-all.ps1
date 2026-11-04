# Runs every test suite and prints one summary. The live suites open Aspen windows (~8 minutes).
#   powershell -ExecutionPolicy Bypass -File tests\run-all.ps1 [-Quick] [-SampleBkp file.bkp] [-ProtectedFile file.bkp]
param([switch]$Quick, [string]$SampleBkp = $env:ASPEN_MCP_SAMPLE_BKP, [string]$ProtectedFile = $env:ASPEN_MCP_PROTECTED_FILE)

$suites = @(@{ name = 'protocol'; args = @('-SampleBkp', "$SampleBkp") }, @{ name = 'install'; args = @() })
if (-not $Quick) {
    $suites += @{ name = 'live'; args = @('-ProtectedFile', "$ProtectedFile") }
    $suites += @{ name = 'models'; args = @() }
    $suites += @{ name = 'advanced'; args = @() }
}
$failed = @()
foreach ($s in $suites) {
    Write-Host "`n=== $($s.name) ===" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$($s.name).tests.ps1") @($s.args)
    if ($LASTEXITCODE -ne 0) { $failed += $s.name }
}
Write-Host ''
if ($failed.Count) { Write-Host "Failed suites: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host "All $($suites.Count) suites passed." -ForegroundColor Green
