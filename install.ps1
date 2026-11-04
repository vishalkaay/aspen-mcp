# Registers (or removes) the Aspen Plus MCP server in Claude Desktop, and in Claude Code if its CLI is installed.
#   powershell -ExecutionPolicy Bypass -File install.ps1             # install / update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall  # remove
# Every config file is backed up next to itself before it is changed. Restart Claude Desktop afterwards.
param([switch]$Uninstall, [string]$Name = 'aspen-plus')

$ErrorActionPreference = 'Stop'
$server = Join-Path $PSScriptRoot 'server.ps1'
$entry = [ordered]@{
    command = 'powershell.exe'
    args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $server)
}

# Claude Desktop keeps its config in %APPDATA%\Claude, or under %LOCALAPPDATA%\Claude-Data\<id> in newer builds.
$configs = @()
$classic = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path $classic) { $configs += $classic }
$configs += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Filter 'claude_desktop_config.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object FullName)
if ($configs.Count -eq 0 -and -not $Uninstall) {
    [void](New-Item -ItemType Directory -Force (Split-Path $classic))
    '{}' | Set-Content $classic -Encoding ascii
    $configs += $classic
}

foreach ($cfg in $configs) {
    $backup = "$cfg.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item $cfg $backup
    $raw = Get-Content $cfg -Raw
    $j = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { $raw | ConvertFrom-Json }
    if (-not ($j.PSObject.Properties.Name -contains 'mcpServers')) { $j | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) }
    if ($Uninstall) {
        $j.mcpServers.PSObject.Properties.Remove($Name)
        $what = 'removed from'
    } else {
        $j.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]$entry) -Force
        $what = 'registered in'
    }
    [IO.File]::WriteAllText($cfg, ($j | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding($false)))
    [void](Get-Content $cfg -Raw | ConvertFrom-Json)   # fail loudly if the result is not valid JSON
    Write-Host "'$Name' $what $cfg (backup: $backup)"
}

$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the script
    & claude mcp remove --scope user $Name
    if (-not $Uninstall) { & claude mcp add --scope user $Name -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $server }
} else {
    Write-Host "Claude Code CLI not found. To add the server there later run:"
    Write-Host "  claude mcp add --scope user $Name -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$server`""
}
if (-not $Uninstall) { Write-Host "Done. Fully quit and reopen Claude Desktop, then start a new chat or session." }
