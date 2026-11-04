# Installs the Aspen Plus MCP server for Claude: Claude Desktop (Chat tab) and Claude Code (the
# desktop app's Code tab and the CLI).
#   powershell -ExecutionPolicy Bypass -File install.ps1              # install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   # remove
# Every config file is backed up next to itself before it is changed, and only the "aspen-plus"
# entry is touched. Start a new Claude session afterwards (MCP servers load when a session starts).
param(
    [switch]$Uninstall,
    [string]$Name = 'aspen-plus',
    [string[]]$DesktopConfig,      # override: Claude Desktop config file(s) to edit (tests)
    [string]$ClaudeCodeConfig      # override: Claude Code config file to edit (tests)
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\JsonEdit.ps1')
. (Join-Path $PSScriptRoot 'lib\Detect.ps1')

function Write-Step([string]$s, [string]$color = 'Gray') { Write-Host $s -ForegroundColor $color }

$server = Join-Path $PSScriptRoot 'server.ps1'
$entry = [ordered]@{
    type    = 'stdio'
    command = 'powershell.exe'
    args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $server)
}
$entryJson = ConvertTo-Json $entry -Depth 5 -Compress

# Write $text to $path after validating it, keeping a timestamped backup of the old file.
function Save-Config([string]$path, [string]$text, [scriptblock]$verify) {
    $parsed = $text | ConvertFrom-Json
    if (-not (& $verify $parsed)) { throw "Refusing to write $path : the edit did not produce the expected result" }
    if (Test-Path $path) { Copy-Item $path ("$path.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss')) }
    else { [void](New-Item -ItemType Directory -Force -Path (Split-Path $path)) }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Update-Config([string]$path, [string]$label) {
    $raw = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
    if ($Uninstall) {
        $new = Remove-JsonSectionEntry $raw 'mcpServers' $Name
        if ($new -eq $raw) { Write-Step "  $label : not registered ($path)"; return }
        Save-Config $path $new { param($j) -not ($j.mcpServers -and ($j.mcpServers.PSObject.Properties.Name -contains $Name)) }
        Write-Step "  $label : removed ($path)" 'Green'
    } else {
        $new = Set-JsonSectionEntry $raw 'mcpServers' $Name $entryJson
        if ($new -eq $raw) { Write-Step "  $label : already up to date ($path)" 'Green'; return }
        Save-Config $path $new { param($j) $j.mcpServers.$Name.args[-1] -eq $server }
        Write-Step "  $label : registered ($path)" 'Green'
    }
}

Write-Host ''
Write-Host "Aspen Plus MCP server - $(if ($Uninstall) { 'uninstall' } else { 'install' })" -ForegroundColor Cyan

if (-not $Uninstall) {
    # Files from a downloaded ZIP carry a "from the internet" mark; clear it so PowerShell runs them quietly.
    Get-ChildItem $PSScriptRoot -Recurse -File -Include *.ps1, *.json | Unblock-File -ErrorAction SilentlyContinue

    Write-Step 'Checking this PC'
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "Windows PowerShell 5.1 or newer is required (found $($PSVersionTable.PSVersion))." }
    $ids = @(Get-AspProgIds)
    if ($ids.Count -gt 0) { Write-Step "  found $(Get-AspVersionName $ids[0]) ($($ids[0]))" 'Green' }
    else { Write-Step '  WARNING: Aspen Plus is not registered on this PC. The server installs, but cannot open simulations until Aspen Plus is installed.' 'Yellow' }
}

Write-Step 'Claude Desktop (Chat tab)'
$desktop = @()
if ($DesktopConfig) { $desktop = @($DesktopConfig | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }   # -File passes a list as one comma-joined string
else {
    $classic = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    if (Test-Path $classic) { $desktop += $classic }
    $desktop += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Filter 'claude_desktop_config.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object FullName)
    if ($desktop.Count -eq 0 -and -not $Uninstall) { $desktop = @($classic) }
}
foreach ($cfg in $desktop) { Update-Config $cfg 'config' }

Write-Step 'Claude Code (Code tab and CLI)'
$cc = if ($ClaudeCodeConfig) { $ClaudeCodeConfig } else { Join-Path $env:USERPROFILE '.claude.json' }
$cli = if ($ClaudeCodeConfig) { $null } else { Get-Command claude -ErrorAction SilentlyContinue }
if ($cli) {
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the script
    & claude mcp remove --scope user $Name 2>$null | Out-Null
    if (-not $Uninstall) { & claude mcp add --scope user $Name -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $server }
    $ErrorActionPreference = 'Stop'
} elseif ((Test-Path $cc) -or -not $Uninstall) {
    Update-Config $cc 'user config'
}

Write-Host ''
if ($Uninstall) {
    Write-Host 'Done. Start a new Claude session for the change to take effect.' -ForegroundColor Cyan
} else {
    Write-Host 'Done. Next:' -ForegroundColor Cyan
    Write-Host '  1. Start a NEW chat or Code session in Claude (MCP tools load at session start).'
    Write-Host '     If the Aspen tools do not appear, fully quit Claude Desktop (tray icon > Quit) and reopen it.'
    Write-Host '  2. Ask: "Start a new Aspen simulation with water and methanol" - an Aspen window opens.'
    Write-Host '  Health check any time:  powershell -ExecutionPolicy Bypass -File check.ps1'
}
