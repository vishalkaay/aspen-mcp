# Tests install.ps1 on temporary config files only (never the real ones). Does not start Aspen.
#   powershell -ExecutionPolicy Bypass -File tests\install.tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'McpClient.ps1')
$install = Join-Path $root 'install.ps1'
$server = Join-Path $root 'server.ps1'

$tmp = Join-Path $env:TEMP ('aspen_mcp_install_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $tmp)
try {
    $files = [ordered]@{
        plain    = '{"preferences": {"sidebarMode": "x", "nested": {"a": [1, 2, {"b": "}{"}]}}, "s": "quote \" and \\ backslash"}'
        others   = "{`n  `"mcpServers`": {`n    `"other`": {`"command`": `"node`", `"args`": [`"x.js`"]}`n  },`n  `"k`": 1`n}"
        emptysec = '{"mcpServers": {}, "z": true}'
        empty    = ''
    }
    # copies of the real configs, when present, to prove large real files survive untouched
    $realCc = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path $realCc) { $files['real_claude_code'] = [IO.File]::ReadAllText($realCc) }
    $realD = @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Filter 'claude_desktop_config.json' -Recurse -Depth 1 -ErrorAction SilentlyContinue)[0]
    if ($realD) { $files['real_desktop'] = [IO.File]::ReadAllText($realD.FullName) }
    $paths = [ordered]@{}
    . (Join-Path $root 'lib\JsonEdit.ps1')
    foreach ($k in @($files.Keys)) {
        $p = Join-Path $tmp "$k.json"
        # start from a version without aspen-plus so the round trip can be compared byte for byte
        $text = Remove-JsonSectionEntry $files[$k] 'mcpServers' 'aspen-plus'
        $files[$k] = $text
        [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($false)))
        $paths[$k] = $p
    }
    $missing = Join-Path $tmp 'sub\missing.json'
    $desk = @($paths.Values) + $missing
    $ccPath = $paths['others']

    function Invoke-Install([switch]$Uninstall) {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $install, '-DesktopConfig', ($desk -join ','), '-ClaudeCodeConfig', $ccPath)
        if ($Uninstall) { $a += '-Uninstall' }
        $out = & powershell.exe @a 2>&1 | Out-String
        return @{ code = $LASTEXITCODE; out = $out }
    }

    $r = Invoke-Install
    Assert-True ($r.code -eq 0) 'install runs' $r.out
    foreach ($k in $paths.Keys + 'missing') {
        $p = if ($k -eq 'missing') { $missing } else { $paths[$k] }
        $j = Get-Content $p -Raw | ConvertFrom-Json
        $e = $j.mcpServers.'aspen-plus'
        Assert-True ($e -and $e.command -eq 'powershell.exe' -and @($e.args)[-1] -eq $server) "${k}: aspen-plus entry points to server.ps1" (Get-Content $p -Raw)
    }
    $j = Get-Content $paths['others'] -Raw | ConvertFrom-Json
    Assert-True ($j.mcpServers.other.command -eq 'node' -and $j.k -eq 1) 'existing MCP servers and keys are kept' (Get-Content $paths['others'] -Raw)
    $j = Get-Content $paths['plain'] -Raw | ConvertFrom-Json
    Assert-True ($j.s -eq 'quote " and \ backslash' -and $j.preferences.nested.a[2].b -eq '}{') 'strings with quotes, backslashes and braces survive' (Get-Content $paths['plain'] -Raw)
    $baks = @(Get-ChildItem $tmp -Filter '*.bak-*')
    Assert-True ($baks.Count -ge $files.Count) "every changed file got a backup ($($baks.Count))"

    $before = @{}; foreach ($k in $paths.Keys) { $before[$k] = [IO.File]::ReadAllText($paths[$k]) }
    $r = Invoke-Install
    $same = @($paths.Keys | Where-Object { [IO.File]::ReadAllText($paths[$_]) -ne $before[$_] }).Count -eq 0
    Assert-True ($r.code -eq 0 -and $same -and $r.out -match 'already up to date') 'running install again changes nothing' $r.out

    $r = Invoke-Install -Uninstall
    Assert-True ($r.code -eq 0) 'uninstall runs' $r.out
    foreach ($k in $paths.Keys) {
        $expect = if ($files[$k] -eq '') { '{}' } else { $files[$k] }   # an empty file comes back as an empty object
        Assert-True ([IO.File]::ReadAllText($paths[$k]) -eq $expect) "${k}: uninstall restores the file byte for byte" ([IO.File]::ReadAllText($paths[$k]))
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Summary
if ($script:Failed -gt 0) { exit 1 }
