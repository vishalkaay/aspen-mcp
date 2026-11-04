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

# Claude Code (CLI, and the Code tab of the desktop app) reads MCP servers from ~/.claude.json,
# not from claude_desktop_config.json.
$claude = Get-Command claude -ErrorAction SilentlyContinue
$cc = Join-Path $env:USERPROFILE '.claude.json'
if ($claude) {
    $ErrorActionPreference = 'Continue'   # native stderr must not abort the script
    & claude mcp remove --scope user $Name
    if (-not $Uninstall) { & claude mcp add --scope user $Name -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $server }
} elseif ((Test-Path $cc) -and -not $Uninstall) {
    # The file is large and owned by Claude Code, so only the one key is inserted as text (no full rewrite).
    $raw = [IO.File]::ReadAllText($cc)
    $j = $raw | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'mcpServers') {
        if ($j.mcpServers.PSObject.Properties.Name -contains $Name) { Write-Host "'$Name' already registered in $cc" }
        else { Write-Host "$cc already has other MCP servers; add '$Name' there by hand (see README)." }
    } else {
        $backup = "$cc.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss')
        Copy-Item $cc $backup
        $e = [ordered]@{ type = 'stdio' } + $entry
        $i = $raw.IndexOf('{')
        $new = $raw.Substring(0, $i + 1) + "`n  `"mcpServers`": {`"$Name`": " + (ConvertTo-Json $e -Depth 5 -Compress) + '},' + $raw.Substring($i + 1)
        [void]($new | ConvertFrom-Json)   # validate before writing
        [IO.File]::WriteAllText($cc, $new, (New-Object Text.UTF8Encoding($false)))
        Write-Host "'$Name' registered for Claude Code in $cc (backup: $backup)"
    }
} elseif ($Uninstall) {
    Write-Host "To remove it from Claude Code, delete mcpServers.$Name from $cc."
}
if (-not $Uninstall) { Write-Host "Done. Fully quit and reopen Claude Desktop, then start a new chat or session." }
