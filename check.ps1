# Health check for the Aspen Plus MCP server. Explains what is wrong and how to fix it.
#   powershell -ExecutionPolicy Bypass -File check.ps1          # quick (does not start Aspen)
#   powershell -ExecutionPolicy Bypass -File check.ps1 -Aspen   # also opens and closes a real Aspen window
param([switch]$Aspen)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Detect.ps1')
. (Join-Path $PSScriptRoot 'tests\McpClient.ps1')

$script:Problems = 0
function Write-Ok([string]$s) { Write-Host "  OK    $s" -ForegroundColor Green }
function Write-Warn([string]$s, [string]$fix) { Write-Host "  WARN  $s" -ForegroundColor Yellow; if ($fix) { Write-Host "        -> $fix" -ForegroundColor DarkYellow } }
function Write-Bad([string]$s, [string]$fix) { $script:Problems++; Write-Host "  FAIL  $s" -ForegroundColor Red; if ($fix) { Write-Host "        -> $fix" -ForegroundColor DarkYellow } }

$server = Join-Path $PSScriptRoot 'server.ps1'
Write-Host "`nAspen Plus MCP server - health check" -ForegroundColor Cyan

Write-Host 'This PC'
if ($env:OS -ne 'Windows_NT') { Write-Bad 'Not Windows' 'Aspen Plus and this server run on Windows only.' } else { Write-Ok "Windows ($([Environment]::OSVersion.Version))" }
if ($PSVersionTable.PSVersion.Major -ge 5) { Write-Ok "PowerShell $($PSVersionTable.PSVersion)" } else { Write-Bad "PowerShell $($PSVersionTable.PSVersion)" 'Windows PowerShell 5.1 is required (it ships with Windows 10/11).' }

Write-Host 'Aspen Plus'
$cfg = @{ progid = 'auto' }
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $cfgPath) {
    try { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json; if ($c.progid) { $cfg.progid = $c.progid }; Write-Ok 'config.json is valid' }
    catch { Write-Bad "config.json is not valid JSON: $($_.Exception.Message)" 'Fix the file or delete it to use the defaults.' }
}
$ids = @(Get-AspProgIds)
if ($ids.Count -gt 0) { Write-Ok "installed: $(($ids | ForEach-Object { "$(Get-AspVersionName $_) ($_)" }) -join ', ')" }
else { Write-Bad 'No Aspen Plus COM registration found' 'Install Aspen Plus (V11 or newer). If it is installed, repair it so its COM server is registered.' }
$progid = Resolve-AspProgId $cfg.progid
if ($null -ne [type]::GetTypeFromProgID($progid)) { Write-Ok "will start $(Get-AspVersionName $progid) ($progid)" }
else { Write-Bad "progid $progid is not registered" 'Set "progid": "auto" in config.json, or one of the installed IDs above.' }

Write-Host 'Claude registration'
$found = 0
$targets = @()
$classic = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path $classic) { $targets += @{ label = 'Claude Desktop'; path = $classic } }
foreach ($f in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Filter 'claude_desktop_config.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue)) { $targets += @{ label = 'Claude Desktop'; path = $f.FullName } }
$cc = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $cc) { $targets += @{ label = 'Claude Code'; path = $cc } }
foreach ($t in $targets) {
    try { $j = Get-Content $t.path -Raw | ConvertFrom-Json } catch { Write-Warn "$($t.label): cannot read $($t.path)" $null; continue }
    $e = $null; if ($j.mcpServers) { $e = $j.mcpServers.'aspen-plus' }
    if (-not $e) { Write-Warn "$($t.label): aspen-plus not registered ($($t.path))" 'Run install.ps1.'; continue }
    $p = @($e.args)[-1]
    if ($p -ieq $server) { $found++; Write-Ok "$($t.label): registered ($($t.path))" }
    else { Write-Warn "$($t.label): registered, but points to $p" 'Run install.ps1 from this folder to point it here.' }
}
if ($found -eq 0) { Write-Bad 'aspen-plus is not registered for Claude Desktop or Claude Code' 'Run install.ps1, then start a new Claude session.' }

Write-Host 'Server'
try {
    [void](Start-McpServer $server)
    $init = Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18' } 30
    $tools = @((Invoke-Mcp 'tools/list' $null 30).result.tools)
    Write-Ok "starts and answers MCP: $($init.result.serverInfo.name) $($init.result.serverInfo.version), $($tools.Count) tools"
    if ($Aspen) {
        Write-Host 'Live Aspen test (opens an Aspen window for ~30 s)'
        $r = Invoke-Tool 'aspen_new' @{ replace = $true } 180
        if ($r.isError) { Write-Bad "aspen_new failed: $($r.text)" 'Check that Aspen Plus starts by hand and that a license is available.' }
        else {
            $i = Invoke-Tool 'aspen_info'
            Write-Ok "opened $($i.json.aspen_version) (pid $($i.json.aspen_pid)), unit set $($i.json.unit_set)"
            $r = Invoke-Tool 'aspen_add_components' @{ components = @('WATER') }
            if (@($r.json.components)[0].found) { Write-Ok 'databank lookup works (WATER = H2O)' } else { Write-Bad 'databank lookup failed' 'Check the Aspen Plus databank installation.' }
            [void](Invoke-Tool 'aspen_close' @{} 60)
            Write-Ok 'closed Aspen'
        }
    }
} catch { Write-Bad "server did not start: $($_.Exception.Message)" "See logs\server.log. Try: powershell -NoProfile -ExecutionPolicy Bypass -File `"$server`"" }
finally { try { Stop-McpServer } catch {} }

Write-Host ''
if ($script:Problems -eq 0) {
    Write-Host 'All good.' -ForegroundColor Green
    if (-not $Aspen) { Write-Host 'Run with -Aspen to also test a real Aspen Plus window.' }
    Write-Host 'In Claude, start a NEW session and ask e.g. "Start a new Aspen simulation with water and methanol".'
} else {
    Write-Host "$script:Problems problem(s) found; see the hints above." -ForegroundColor Red
    exit 1
}
